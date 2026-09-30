"""VO1D realtime gateway.

HTTP keeps the existing opaque mailbox API. WSS /v1/call/socket routes
short-lived encrypted call frames between authenticated identities. The relay
never receives audio plaintext.
"""
import asyncio
import base64
import hashlib
import json
import os
import re
import secrets
import time
from pathlib import Path
from aiohttp import WSMsgType, web

from push import PushService
import call_authority
import private_blobs
from app import APIError, ID, MAX_BODY, UUID, Relay

CALL_MAX_AUDIO = 96 * 1024
CALL_MAX_TEXT = 140 * 1024
BLOB_MAX_BYTES = 50 * 1024 * 1024 + 64
BLOB_OWNER_QUOTA = 500 * 1024 * 1024
BLOB_RETENTION = max(60,min(7*86400,int(os.environ.get("VO1D_BLOB_RETENTION",str(7*86400)))))
BLOB_ID = re.compile(r"^[A-Za-z0-9_-]{40,64}$")


class RealtimeGateway:
    def __init__(self):
        self.relay = Relay()
        self.push = PushService(self.relay)
        self.clients = {}
        self.calls = {}
        self.lock = asyncio.Lock()
        self.active_uploads = 0
        self.blob_dir = Path(os.environ.get("VO1D_BLOB_DIR", "/data/blobs"))
        self.blob_dir.mkdir(parents=True, exist_ok=True)
        self._cleanup_blobs(include_orphans=True)

    def _env(self, request):
        return {
            "REQUEST_METHOD": request.method,
            "PATH_INFO": request.path,
            "REMOTE_ADDR": request.remote or "",
            "HTTP_AUTHORIZATION": request.headers.get("Authorization", ""),
            "HTTP_X_FORWARDED_FOR": request.headers.get("X-Forwarded-For", ""),
        }

    def _user(self, request):
        with self.relay.db() as db:
            self.relay.clean(db)
            return self.relay.user(self._env(request), db)

    def _blob_path(self, blob_id):
        if not isinstance(blob_id, str) or not BLOB_ID.fullmatch(blob_id):
            raise APIError(400, "Invalid blob id")
        return self.blob_dir / blob_id

    def _cleanup_blobs(self, include_orphans=False):
        now = int(time.time())
        with self.relay.db() as db:
            expired = [row["id"] for row in db.execute(
                "SELECT id FROM blobs WHERE expires<=?", (now,)
            ).fetchall()]
            if expired:
                db.executemany("DELETE FROM blobs WHERE id=?", [(blob_id,) for blob_id in expired])
            expired += [r[0] for r in db.execute("SELECT id FROM private_blobs WHERE expires<=?", (now,)).fetchall()]
            db.execute("DELETE FROM private_blobs WHERE expires<=?", (now,))
            db.execute("DELETE FROM private_blob_seen WHERE expires<=?", (now,))
            live = set()
            if include_orphans:
                live = {row[0] for row in db.execute("SELECT id FROM blobs UNION SELECT id FROM private_blobs").fetchall()}

        for blob_id in expired:
            try:
                self._blob_path(blob_id).unlink(missing_ok=True)
            except (OSError, APIError):
                pass

        if include_orphans:
            try:
                for item in self.blob_dir.iterdir():
                    if item.is_file() and item.name not in live and time.time()-item.stat().st_mtime>3600:
                        item.unlink(missing_ok=True)
            except OSError:
                pass

    @staticmethod
    def _prepare_blob(path, data):
        temp = path.with_name(path.name + ".tmp-" + secrets.token_hex(8))
        try:
            with open(temp, "xb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            return temp
        except BaseException:
            temp.unlink(missing_ok=True)
            raise

    async def blob_upload(self, request):
        blob_id, temp, complete = None, None, False
        entered = False
        try:
            user = self._user(request)
            self.relay.rate("blob-upload:" + user, 80, 3600)
            self._cleanup_blobs()
            length = request.content_length
            if request.content_type != "application/octet-stream":
                raise APIError(415, "Encrypted binary blob required")
            if length is None or not 29 <= length <= BLOB_MAX_BYTES:
                raise APIError(413, "Blob exceeds size limit")
            if self.active_uploads >= 4:
                raise APIError(429, "Concurrent upload limit reached")
            self.active_uploads += 1
            entered = True
            blob_id, now = secrets.token_urlsafe(32), int(time.time())
            expires = now + BLOB_RETENTION
            with self.relay.db() as db:
                db.execute("BEGIN IMMEDIATE")
                count, total = db.execute("SELECT count(*),coalesce(sum(size),0) FROM blobs WHERE owner=? AND expires>?", (user,now)).fetchone()
                if count >= 200 or total + length > BLOB_OWNER_QUOTA:
                    raise APIError(429, "Blob quota exceeded")
                db.execute("INSERT INTO blobs VALUES (?,?,?,?,?,?)", (blob_id,user,length,"",now,expires))
            payload = await request.read()
            if len(payload) != length:
                raise APIError(400, "Blob length mismatch")
            digest = hashlib.sha256(payload).hexdigest()
            temp = await asyncio.to_thread(self._prepare_blob, self._blob_path(blob_id), payload)
            with self.relay.db() as db:
                db.execute("BEGIN IMMEDIATE")
                row = db.execute("SELECT 1 FROM blobs WHERE id=? AND owner=? AND digest=''", (blob_id,user)).fetchone()
                if not row or not db.execute("SELECT 1 FROM identities WHERE id=?", (user,)).fetchone():
                    raise APIError(410, "Upload authority revoked")
                os.replace(temp, self._blob_path(blob_id))
                db.execute("UPDATE blobs SET digest=? WHERE id=?", (digest,blob_id))
            complete = True
            return web.json_response({"id":blob_id,"size":length,"digest":digest,"expiresAt":expires}, headers={"Cache-Control":"no-store"})
        except APIError as exc:
            return self._blob_error(exc)
        except (OSError, ValueError):
            return self._blob_error(APIError(503, "Blob upload unavailable"))
        finally:
            if entered:
                self.active_uploads -= 1
            if temp:
                temp.unlink(missing_ok=True)
            if blob_id and not complete:
                with self.relay.db() as db:
                    db.execute("DELETE FROM blobs WHERE id=? AND digest=''", (blob_id,))

    @staticmethod
    def _blob_error(exc):
        return web.json_response({"error":exc.message}, status=exc.status, headers={"Cache-Control":"no-store"})

    async def _stream_blob(self, request, blob_id, row):
        # Open before yielding: deletion revokes future requests while an already
        # authorized transfer holds its own descriptor, including Range requests.
        try:
            handle = open(self._blob_path(blob_id), "rb")
        except FileNotFoundError:
            raise APIError(404, "Blob not found")
        with handle:
            size = os.fstat(handle.fileno()).st_size
            if size != row["size"]:
                raise APIError(404, "Blob unavailable")
            start, end, status = 0, size - 1, 200
            raw_range = request.headers.get("Range")
            if raw_range:
                match = re.fullmatch(r"bytes=(\d*)-(\d*)", raw_range)
                if not match or not any(match.groups()):
                    return web.Response(status=416, headers={"Content-Range":f"bytes */{size}","Cache-Control":"no-store"})
                a, b = match.groups()
                if a:
                    start = int(a)
                    end = min(size - 1, int(b)) if b else size - 1
                else:
                    start = max(0, size - int(b))
                if start >= size or end < start or (not a and int(b) == 0):
                    return web.Response(status=416, headers={"Content-Range":f"bytes */{size}","Cache-Control":"no-store"})
                status = 206
            headers = {"Content-Type":"application/octet-stream", "Content-Length":str(end-start+1),
                       "Accept-Ranges":"bytes", "Cache-Control":"private, no-store", "X-Content-Type-Options":"nosniff",
                       "X-VO1D-Blob-Digest":row["digest"]}
            if status == 206:
                headers["Content-Range"] = f"bytes {start}-{end}/{size}"
            response = web.StreamResponse(status=status, headers=headers)
            await response.prepare(request)
            if request.method != "HEAD":
                handle.seek(start)
                remaining = end-start+1
                try:
                    while remaining:
                        data = await asyncio.to_thread(handle.read, min(65536,remaining))
                        if not data:
                            break
                        await response.write(data)
                        remaining -= len(data)
                except (ConnectionError, asyncio.CancelledError):
                    return response
            await response.write_eof()
            return response

    async def blob_download(self, request):
        try:
            user = self._user(request)
            self.relay.rate("blob-download:" + user, 240, 3600)
            self._cleanup_blobs()
            blob_id = request.match_info.get("blob_id", "")
            self._blob_path(blob_id)
            with self.relay.db() as db:
                row = db.execute("SELECT size,digest,expires FROM blobs WHERE id=? AND expires>? AND digest<>''", (blob_id,int(time.time()))).fetchone()
            if not row:
                raise APIError(404, "Blob not found")
            return await self._stream_blob(request,blob_id,row)
        except APIError as exc:
            return self._blob_error(exc)

    async def private_blob(self, request):
        blob_id = request.match_info.get("blob_id", "")
        temp, lease, complete, entered = None, None, False, False
        try:
            self._blob_path(blob_id)
            self._cleanup_blobs()
            scope = "upload" if request.method == "PUT" else "delete" if request.method == "DELETE" else "read"
            auth = request.headers.get("Authorization", "")
            self.relay.rate("blob-capability:"+private_blobs.digest(auth),240,3600)
            with self.relay.db() as db:
                db.execute("BEGIN IMMEDIATE")
                row = private_blobs.authorize(db,blob_id,auth,scope,APIError)
                if scope == "delete":
                    db.execute("DELETE FROM private_blobs WHERE id=?", (blob_id,))
                elif scope == "upload":
                    if request.content_type != "application/octet-stream":
                        raise APIError(415, "Encrypted binary blob required")
                    if request.content_length != row["size"]:
                        raise APIError(400, "Blob length mismatch")
                    if row["uploaded"] == 1:
                        return web.json_response({"id":blob_id,"size":row["size"],"digest":row["digest"],"expiresAt":row["expires"]},headers={"Cache-Control":"no-store"})
                    if row["uploaded"] == -1 and row["lease"] > int(time.time()):
                        raise APIError(409, "Blob upload already active")
                    if self.active_uploads >= 4:
                        raise APIError(429, "Concurrent upload limit reached")
                    self.active_uploads += 1
                    entered = True
                    lease = int(time.time()) + 300
                    db.execute("UPDATE private_blobs SET uploaded=-1,lease=? WHERE id=?", (lease,blob_id))
                elif row["uploaded"] != 1:
                    raise APIError(404, "Blob not uploaded")
            if scope == "delete":
                self._blob_path(blob_id).unlink(missing_ok=True)
                return web.json_response({"ok":True}, headers={"Cache-Control":"no-store"})
            if scope == "read":
                return await self._stream_blob(request,blob_id,row)
            data = await request.read()
            if len(data) != row["size"] or hashlib.sha256(data).hexdigest() != row["digest"]:
                raise APIError(400, "Blob integrity mismatch")
            temp = await asyncio.to_thread(self._prepare_blob,self._blob_path(blob_id),data)
            with self.relay.db() as db:
                db.execute("BEGIN IMMEDIATE")
                valid = db.execute("SELECT 1 FROM private_blobs WHERE id=? AND uploaded=-1 AND lease=? AND expires>?", (blob_id,lease,int(time.time()))).fetchone()
                if not valid:
                    raise APIError(410, "Upload authority revoked")
                os.replace(temp,self._blob_path(blob_id))
                db.execute("UPDATE private_blobs SET uploaded=1,lease=0 WHERE id=?", (blob_id,))
            complete = True
            return web.json_response({"id":blob_id,"size":row["size"],"digest":row["digest"],"expiresAt":row["expires"]},headers={"Cache-Control":"no-store"})
        except APIError as exc:
            return self._blob_error(exc)
        except (OSError, ValueError):
            return self._blob_error(APIError(503, "Blob transfer unavailable"))
        finally:
            if entered:
                self.active_uploads -= 1
            if temp:
                temp.unlink(missing_ok=True)
            if lease and not complete:
                with self.relay.db() as db:
                    db.execute("UPDATE private_blobs SET uploaded=0,lease=0 WHERE id=? AND uploaded=-1 AND lease=?", (blob_id,lease))

    async def blob_delete(self, request):
        try:
            user = self._user(request)
            blob_id = request.match_info.get("blob_id", "")
            path = self._blob_path(blob_id)

            with self.relay.db() as db:
                row = db.execute("SELECT owner FROM blobs WHERE id=?", (blob_id,)).fetchone()
                if not row:
                    return web.json_response({"ok": True}, headers={"Cache-Control": "no-store"})
                if row["owner"] != user:
                    raise APIError(403, "Blob owner required")
                db.execute("DELETE FROM blobs WHERE id=?", (blob_id,))

            path.unlink(missing_ok=True)
            return web.json_response({"ok": True}, headers={"Cache-Control": "no-store"})
        except APIError as exc:
            return web.json_response(
                {"error": exc.message},
                status=exc.status,
                headers={"Cache-Control": "no-store"}
            )

    async def http(self, request):
        try:
            length = request.content_length or 0
            if length < 0 or length > MAX_BODY:
                raise APIError(413, "Request too large")
            if request.method == "POST" and request.content_type != "application/json":
                raise APIError(415, "JSON required")

            raw = await request.read()
            if len(raw) > MAX_BODY: raise APIError(413,"Request too large")
            body = json.loads(raw) if raw else {}
            if not isinstance(body, dict):
                raise APIError(400, "JSON object required")
            result = self.relay.dispatch(self._env(request), body)
            status = 200
            if request.method == "POST" and request.path == "/v1/envelopes":
                target=body.get("recipient")
                with self.relay.db() as db:
                    stored=db.execute("SELECT 1 FROM envelopes WHERE id=? AND recipient=?",(body.get("id"),target)).fetchone()
                if stored:
                    await self.push.send(target)
            if request.method == "DELETE" and request.path == "/v1/account":
                self._cleanup_blobs(include_orphans=True)
        except APIError as exc:
            result, status = {"error": exc.message}, exc.status
        except (ValueError, TypeError, KeyError, UnicodeError, RecursionError):
            result, status = {"error": "Invalid request"}, 400
        except Exception:
            result, status = {"error": "Relay unavailable"}, 500

        return web.json_response(
            result,
            status=status,
            headers={
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
            },
        )

    def _peer_for(self, route, user):
        if user == route["a"]:
            return route["b"]
        if user == route["b"]:
            return route["a"]
        return None

    def _busy(self, identity):
        return any(identity in (route["a"], route["b"]) for route in self.calls.values())

    async def _send_error(self, ws, code):
        try:
            await ws.send_json({"type": "error", "code": code})
        except Exception:
            pass

    async def _forward(self, target, payload):
        async with self.lock:
            ws = self.clients.get(target)
        if ws is None or ws.closed:
            return False
        try:
            await ws.send_json(payload)
            return True
        except Exception:
            return False

    async def websocket(self, request):
        try:
            auth=request.headers.get('Authorization','')
            delegated=None
            if auth.startswith('CallCapability '):
                with self.relay.db() as db:
                    user,delegated=call_authority.authorize(db,auth,APIError)
            else:
                user = self._user(request)
            with self.relay.db() as db:
                own_card=db.execute('SELECT card FROM identities WHERE id=?',(user,)).fetchone()
            if own_card is None: raise APIError(401,'Identity unavailable')
            extra={'card':base64.b64encode(own_card[0].encode()).decode()}
            if delegated is not None:
                extra['certificate']=base64.b64encode(json.dumps(delegated).encode()).decode()
        except APIError as exc:
            raise web.HTTPUnauthorized(text=exc.message)

        ws = web.WebSocketResponse(
            heartbeat=20,
            receive_timeout=70,
            max_msg_size=CALL_MAX_TEXT,
            autoping=True,
        )
        await ws.prepare(request)

        async with self.lock:
            old = self.clients.get(user)
            self.clients[user] = ws
        if old is not None and old is not ws and not old.closed:
            await old.close(code=4001, message=b"replaced")

        await ws.send_json({"type": "ready"})
        for call_id, route in list(self.calls.items()):
            if route["b"] == user and not route["accepted"]:
                await ws.send_json({"type":"invite","from":route["a"],"callID":call_id,"key":route["key"],"keySignature":route["keySignature"],**route.get('extra',{})})

        try:
            async for message in ws:
                if delegated is not None:
                    try:
                        with self.relay.db() as db: call_authority.authorize(db,auth,APIError)
                    except APIError:
                        await ws.close(code=4003,message=b'authority revoked')
                        break
                if message.type != WSMsgType.TEXT:
                    if message.type in (WSMsgType.ERROR, WSMsgType.CLOSE, WSMsgType.CLOSING):
                        break
                    continue
                if len(message.data) > CALL_MAX_TEXT:
                    await self._send_error(ws, "frame_too_large")
                    continue

                try:
                    packet = json.loads(message.data)
                except (ValueError, TypeError, RecursionError):
                    await self._send_error(ws, "invalid_json")
                    continue

                if not isinstance(packet, dict):
                    await self._send_error(ws, "invalid_packet")
                    continue

                kind = packet.get("type")
                target = packet.get("to")
                call_id = packet.get("callID")

                if not isinstance(kind,str) or kind not in {"invite", "answer", "audio", "end", "resume", "resumed"}:
                    await self._send_error(ws, "invalid_type")
                    continue
                if not isinstance(target, str) or not ID.fullmatch(target) or target == user:
                    await self._send_error(ws, "invalid_peer")
                    continue
                if not isinstance(call_id, str) or not UUID.fullmatch(call_id):
                    await self._send_error(ws, "invalid_call")
                    continue

                if kind in ("invite","answer"):
                    key,signature=packet.get("key"),packet.get("keySignature")
                    try:
                        if not isinstance(key,str) or not isinstance(signature,str) or len(base64.b64decode(key,validate=True))!=32 or len(base64.b64decode(signature,validate=True))!=64:
                            raise ValueError()
                    except (ValueError,TypeError):
                        await self._send_error(ws,"invalid_call_key")
                        continue
                if kind == "invite":
                    try:
                        self.relay.rate("call-invite:"+user,12)
                    except APIError:
                        await self._send_error(ws,"call_rate_limit")
                        continue
                    with self.relay.db() as db:
                        known = db.execute("SELECT 1 FROM identities WHERE id=?", (target,)).fetchone()
                        blocked = db.execute(
                            "SELECT 1 FROM blocks WHERE owner=? AND peer=?",
                            (target, user),
                        ).fetchone()
                        settings=db.execute("SELECT trusted_calls FROM privacy WHERE identity=?",(target,)).fetchone()
                        trusted=db.execute("SELECT 1 FROM trusted WHERE owner=? AND peer=?",(target,user)).fetchone()
                        if settings and settings[0] and not trusted:
                            blocked=True
                    if not known:
                        await self._send_error(ws, "unknown_peer")
                        continue
                    async with self.lock:
                        peer_ws = self.clients.get(target)
                        if call_id in self.calls:
                            await self._send_error(ws,"call_id_in_use")
                            continue
                        busy = self._busy(user) or self._busy(target)
                        if peer_ws is None or peer_ws.closed:
                            peer_ws = None
                        if not busy and not blocked:
                            self.calls[call_id] = {"a": user, "b": target, "accepted": False,"created":time.monotonic(),"key":key,"keySignature":signature,"extra":extra}
                    if blocked:
                        await self._send_error(ws, "peer_unavailable")
                        continue
                    if busy:
                        await self._send_error(ws, "peer_busy")
                        continue
                    if peer_ws is None:
                        delivered=await self.push.send(target,"voip",{"id":call_id,"from":user})
                        if not delivered:
                            async with self.lock:
                                self.calls.pop(call_id,None)
                            await self._send_error(ws,"peer_offline")
                        continue
                    await self._forward(target, {"type": "invite", "from": user, "callID": call_id,"key":key,"keySignature":signature,**extra})
                    continue

                async with self.lock:
                    route = self.calls.get(call_id)
                if route is None:
                    await self._send_error(ws, "unknown_call")
                    continue
                peer = self._peer_for(route, user)
                if peer != target:
                    await self._send_error(ws, "call_mismatch")
                    continue

                if kind == "answer":
                    if user != route["b"]:
                        await self._send_error(ws, "invalid_answer")
                        continue
                    async with self.lock:
                        if call_id in self.calls:
                            self.calls[call_id]["accepted"] = True
                    await self._forward(peer, {"type": "answer", "from": user, "callID": call_id,"key":key,"keySignature":signature,**extra})
                    continue

                if kind in ("resume", "resumed"):
                    payload, sequence = packet.get("payload"), packet.get("sequence")
                    if not route["accepted"] or not isinstance(sequence,str) or not sequence.isdigit() or len(sequence)>20:
                        await self._send_error(ws,"invalid_resume")
                        continue
                    try:
                        if not isinstance(payload,str) or not 28 <= len(base64.b64decode(payload,validate=True)) <= 256:
                            raise ValueError()
                    except (ValueError,TypeError):
                        await self._send_error(ws,"invalid_resume")
                        continue
                    route.get("paused",set()).discard(user)
                    if not route.get("paused"):
                        route.pop("resumeDeadline",None)
                    await self._forward(peer,{"type":kind,"from":user,"callID":call_id,"payload":payload,"sequence":sequence})
                    continue

                if kind == "audio":
                    if not route["accepted"] or route.get("paused"):
                        continue
                    sequence=packet.get("sequence","")
                    if not isinstance(sequence,str) or not sequence.isdigit() or len(sequence)>20:
                        continue
                    payload = packet.get("payload")
                    if not isinstance(payload, str):
                        continue
                    try:
                        decoded = base64.b64decode(payload, validate=True)
                    except (ValueError, TypeError):
                        continue
                    if not decoded or len(decoded) > CALL_MAX_AUDIO:
                        continue
                    await self._forward(
                        peer,
                        {
                            "type": "audio",
                            "from": user,
                            "callID": call_id,
                            "payload": payload,
                            "sequence":sequence,
                        },
                    )
                    continue

                if kind == "end":
                    await self._forward(peer, {"type": "end", "from": user, "callID": call_id})
                    async with self.lock:
                        self.calls.pop(call_id, None)
                    continue
        finally:
            ended, paused = [], []
            async with self.lock:
                # A replaced socket must not close the replacement's call.
                if self.clients.get(user) is ws:
                    self.clients.pop(user,None)
                    for call_id,route in list(self.calls.items()):
                        if user not in (route["a"],route["b"]):
                            continue
                        peer = self._peer_for(route,user)
                        if route["accepted"]:
                            route.setdefault("paused",set()).add(user)
                            route.setdefault("resumeDeadline",time.monotonic()+20)
                            paused.append((call_id,peer))
                        else:
                            ended.append((call_id,peer))
                            self.calls.pop(call_id,None)
            for kind,items in (("paused",paused),("end",ended)):
                for call_id,peer in items:
                    if peer:
                        await self._forward(peer,{"type":kind,"from":user,"callID":call_id,"reason":"disconnect"})

        return ws


def create_app():
    gateway = RealtimeGateway()
    app = web.Application(client_max_size=BLOB_MAX_BYTES)
    app.router.add_get("/v1/call/socket", gateway.websocket)
    app.router.add_put("/v1/blob", gateway.blob_upload)
    app.router.add_get("/v1/blob/{blob_id}", gateway.blob_download)
    app.router.add_delete("/v1/blob/{blob_id}", gateway.blob_delete)
    app.router.add_route("GET", "/v2/blobs/{blob_id}", gateway.private_blob)
    app.router.add_route("HEAD", "/v2/blobs/{blob_id}", gateway.private_blob)
    app.router.add_route("PUT", "/v2/blobs/{blob_id}", gateway.private_blob)
    app.router.add_route("DELETE", "/v2/blobs/{blob_id}", gateway.private_blob)
    app.router.add_route("*", "/{tail:.*}", gateway.http)
    async def maintenance(app):
        async def loop():
            while True:
                await asyncio.sleep(30)
                with gateway.relay.db() as db:
                    gateway.relay.clean(db)
                gateway._cleanup_blobs(include_orphans=True)
                for call_id,route in list(gateway.calls.items()):
                    if (not route["accepted"] and time.monotonic()-route.get("created",0)>60) or (route.get("resumeDeadline",float("inf")) < time.monotonic()):
                        gateway.calls.pop(call_id,None)
                        for user in (route["a"],route["b"]):
                            await gateway._forward(user,{"type":"end","from":gateway._peer_for(route,user),"callID":call_id,"reason":"timeout"})
        task=asyncio.create_task(loop())
        yield
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        await gateway.push.close()
    app.cleanup_ctx.append(maintenance)
    return app


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    web.run_app(
        create_app(),
        host="0.0.0.0",
        port=port,
        access_log=None,
        print=lambda *args, **kwargs: None,
    )
