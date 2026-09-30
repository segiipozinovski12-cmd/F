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
from app import APIError, ID, MAX_BODY, UUID, Relay

CALL_MAX_AUDIO = 96 * 1024
CALL_MAX_TEXT = 140 * 1024
BLOB_MAX_BYTES = 50 * 1024 * 1024 + 64
BLOB_OWNER_QUOTA = 500 * 1024 * 1024
BLOB_RETENTION = 30 * 86400
BLOB_ID = re.compile(r"^[A-Za-z0-9_-]{40,64}$")


class RealtimeGateway:
    def __init__(self):
        self.relay = Relay()
        self.push = PushService(self.relay)
        self.clients = {}
        self.calls = {}
        self.lock = asyncio.Lock()
        self.blob_dir = Path(os.environ.get("VO1D_BLOB_DIR", "/data/blobs"))
        self.blob_dir.mkdir(parents=True, exist_ok=True)
        self._cleanup_blobs(include_orphans=True)

    def _env(self, request):
        return {
            "REQUEST_METHOD": request.method,
            "PATH_INFO": request.path,
            "REMOTE_ADDR": request.remote or "",
            "HTTP_AUTHORIZATION": request.headers.get("Authorization", ""),
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
            live = set()
            if include_orphans:
                live = {row["id"] for row in db.execute("SELECT id FROM blobs").fetchall()}

        for blob_id in expired:
            try:
                self._blob_path(blob_id).unlink(missing_ok=True)
            except (OSError, APIError):
                pass

        if include_orphans:
            try:
                for item in self.blob_dir.iterdir():
                    if item.is_file() and item.name not in live:
                        item.unlink(missing_ok=True)
            except OSError:
                pass

    @staticmethod
    def _write_blob(path, data):
        temp = path.with_name(path.name + ".tmp-" + secrets.token_hex(8))
        try:
            with open(temp, "xb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp, path)
        finally:
            try:
                temp.unlink(missing_ok=True)
            except OSError:
                pass

    async def blob_upload(self, request):
        try:
            user = self._user(request)
            self.relay.rate("blob-upload:" + user, 80, 3600)
            self._cleanup_blobs()

            if request.content_type != "application/octet-stream":
                raise APIError(415, "Encrypted binary blob required")

            length = request.content_length
            if length is None or length < 29 or length > BLOB_MAX_BYTES:
                raise APIError(413, "Blob exceeds size limit")

            with self.relay.db() as db:
                count, total = db.execute(
                    "SELECT count(*),coalesce(sum(size),0) FROM blobs WHERE owner=? AND expires>?",
                    (user, int(time.time()))
                ).fetchone()
            if count >= 200 or total + length > BLOB_OWNER_QUOTA:
                raise APIError(429, "Blob quota exceeded")

            payload = await request.read()
            if len(payload) != length or len(payload) > BLOB_MAX_BYTES:
                raise APIError(413, "Blob exceeds size limit")

            blob_id = secrets.token_urlsafe(32)
            path = self._blob_path(blob_id)
            digest = hashlib.sha256(payload).hexdigest()
            now = int(time.time())
            expires = now + BLOB_RETENTION

            await asyncio.to_thread(self._write_blob, path, payload)
            try:
                with self.relay.db() as db:
                    db.execute(
                        "INSERT INTO blobs(id,owner,size,digest,created,expires) VALUES (?,?,?,?,?,?)",
                        (blob_id, user, len(payload), digest, now, expires)
                    )
            except Exception:
                path.unlink(missing_ok=True)
                raise

            return web.json_response(
                {
                    "id": blob_id,
                    "size": len(payload),
                    "digest": digest,
                    "expiresAt": expires
                },
                headers={"Cache-Control": "no-store"}
            )
        except APIError as exc:
            return web.json_response(
                {"error": exc.message},
                status=exc.status,
                headers={"Cache-Control": "no-store"}
            )
        except Exception:
            return web.json_response(
                {"error": "Blob upload unavailable"},
                status=500,
                headers={"Cache-Control": "no-store"}
            )

    async def blob_download(self, request):
        try:
            user = self._user(request)
            self.relay.rate("blob-download:" + user, 240, 3600)
            self._cleanup_blobs()

            blob_id = request.match_info.get("blob_id", "")
            path = self._blob_path(blob_id)

            with self.relay.db() as db:
                row = db.execute(
                    "SELECT size,digest,expires FROM blobs WHERE id=? AND expires>?",
                    (blob_id, int(time.time()))
                ).fetchone()
            if not row or not path.is_file():
                raise APIError(404, "Blob not found")

            response = web.FileResponse(path)
            response.content_type = "application/octet-stream"
            response.headers["Cache-Control"] = "private, no-store"
            response.headers["X-Content-Type-Options"] = "nosniff"
            response.headers["X-VO1D-Blob-Digest"] = row["digest"]
            response.headers["Content-Length"] = str(row["size"])
            return response
        except APIError as exc:
            return web.json_response(
                {"error": exc.message},
                status=exc.status,
                headers={"Cache-Control": "no-store"}
            )

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
        except (ValueError, TypeError, KeyError, UnicodeError, json.JSONDecodeError):
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
            user = self._user(request)
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
                await ws.send_json({"type":"invite","from":route["a"],"callID":call_id})

        try:
            async for message in ws:
                if message.type != WSMsgType.TEXT:
                    if message.type in (WSMsgType.ERROR, WSMsgType.CLOSE, WSMsgType.CLOSING):
                        break
                    continue
                if len(message.data) > CALL_MAX_TEXT:
                    await self._send_error(ws, "frame_too_large")
                    continue

                try:
                    packet = json.loads(message.data)
                except (ValueError, TypeError):
                    await self._send_error(ws, "invalid_json")
                    continue

                if not isinstance(packet, dict):
                    await self._send_error(ws, "invalid_packet")
                    continue

                kind = packet.get("type")
                target = packet.get("to")
                call_id = packet.get("callID")

                if kind not in {"invite", "answer", "audio", "end"}:
                    await self._send_error(ws, "invalid_type")
                    continue
                if not isinstance(target, str) or not ID.fullmatch(target) or target == user:
                    await self._send_error(ws, "invalid_peer")
                    continue
                if not isinstance(call_id, str) or not UUID.fullmatch(call_id):
                    await self._send_error(ws, "invalid_call")
                    continue

                if kind == "invite":
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
                            self.calls[call_id] = {"a": user, "b": target, "accepted": False,"created":time.monotonic()}
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
                    await self._forward(target, {"type": "invite", "from": user, "callID": call_id})
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
                    await self._forward(peer, {"type": "answer", "from": user, "callID": call_id})
                    continue

                if kind == "audio":
                    if not route["accepted"]:
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
                        },
                    )
                    continue

                if kind == "end":
                    await self._forward(peer, {"type": "end", "from": user, "callID": call_id})
                    async with self.lock:
                        self.calls.pop(call_id, None)
                    continue
        finally:
            async with self.lock:
                if self.clients.get(user) is ws:
                    self.clients.pop(user, None)
                ended = [
                    (call_id, self._peer_for(route, user))
                    for call_id, route in self.calls.items()
                    if user in (route["a"], route["b"])
                ]
                for call_id, _ in ended:
                    self.calls.pop(call_id, None)

            for call_id, peer in ended:
                if peer:
                    await self._forward(
                        peer,
                        {"type": "end", "from": user, "callID": call_id, "reason": "disconnect"},
                    )

        return ws


def create_app():
    gateway = RealtimeGateway()
    app = web.Application(client_max_size=BLOB_MAX_BYTES)
    app.router.add_get("/v1/call/socket", gateway.websocket)
    app.router.add_put("/v1/blob", gateway.blob_upload)
    app.router.add_get("/v1/blob/{blob_id}", gateway.blob_download)
    app.router.add_delete("/v1/blob/{blob_id}", gateway.blob_delete)
    app.router.add_route("*", "/{tail:.*}", gateway.http)
    async def maintenance(app):
        async def loop():
            while True:
                await asyncio.sleep(30)
                with gateway.relay.db() as db:
                    gateway.relay.clean(db)
                gateway._cleanup_blobs(include_orphans=True)
                for call_id,route in list(gateway.calls.items()):
                    if not route["accepted"] and time.monotonic()-route.get("created",0)>60:
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

