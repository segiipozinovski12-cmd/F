"""VO1D realtime gateway.

HTTP keeps the existing opaque mailbox API. WSS /v1/call/socket routes
short-lived encrypted call frames between authenticated identities. The relay
never receives audio plaintext.
"""
import asyncio
import base64
import json
import os
from aiohttp import WSMsgType, web

from app import APIError, ID, MAX_BODY, UUID, Relay

CALL_MAX_AUDIO = 96 * 1024
CALL_MAX_TEXT = 140 * 1024


class RealtimeGateway:
    def __init__(self):
        self.relay = Relay()
        self.clients = {}
        self.calls = {}
        self.lock = asyncio.Lock()

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
                    if not known:
                        await self._send_error(ws, "unknown_peer")
                        continue
                    async with self.lock:
                        peer_ws = self.clients.get(target)
                        busy = self._busy(user) or self._busy(target)
                        if peer_ws is None or peer_ws.closed:
                            peer_ws = None
                        if not busy and not blocked and peer_ws is not None:
                            self.calls[call_id] = {"a": user, "b": target, "accepted": False}
                    if blocked:
                        await self._send_error(ws, "peer_unavailable")
                        continue
                    if busy:
                        await self._send_error(ws, "peer_busy")
                        continue
                    if peer_ws is None:
                        await self._send_error(ws, "peer_offline")
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
    app = web.Application(client_max_size=MAX_BODY)
    app.router.add_get("/v1/call/socket", gateway.websocket)
    app.router.add_route("*", "/{tail:.*}", gateway.http)
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
