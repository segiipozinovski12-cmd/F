"""APNs delivery with neutral payloads. Credentials live in operator environment."""
import asyncio
import base64
import json
import os
import time
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils


def b64url(data):
    return base64.urlsafe_b64encode(data).decode().rstrip('=')


class PushService:
    def __init__(self, relay):
        self.relay = relay
        self.key_id = os.environ.get('VO1D_APNS_KEY_ID','')
        self.team_id = os.environ.get('VO1D_APNS_TEAM_ID','')
        self.topic = os.environ.get('VO1D_APNS_TOPIC','io.vo1d.messenger')
        self.key_path = os.environ.get('VO1D_APNS_KEY_PATH','')
        self._cached = None
        self._debounce = {}
        self._client = None
        self._lock = asyncio.Lock()

    @property
    def configured(self):
        return bool(self.key_id and self.team_id and self.key_path and Path(self.key_path).is_file())

    def jwt(self):
        now = int(time.time())
        if self._cached and now-self._cached[0]<3000:
            return self._cached[1]
        private = serialization.load_pem_private_key(Path(self.key_path).read_bytes(),password=None)
        if not isinstance(private,ec.EllipticCurvePrivateKey) or not isinstance(private.curve,ec.SECP256R1):
            raise ValueError('APNs requires a P-256 private key')
        header=b64url(json.dumps({'alg':'ES256','kid':self.key_id},separators=(',',':')).encode())
        claims=b64url(json.dumps({'iss':self.team_id,'iat':now},separators=(',',':')).encode())
        content=header+'.'+claims
        r,s=utils.decode_dss_signature(private.sign(content.encode(),ec.ECDSA(hashes.SHA256())))
        token=content+'.'+b64url(r.to_bytes(32,'big')+s.to_bytes(32,'big'))
        self._cached=(now,token)
        return token

    async def send(self, identity, kind='alert', call=None):
        if not self.configured:
            return False
        if kind=='alert':
            now=time.monotonic()
            if now-self._debounce.get(identity,0)<10:
                return False
            self._debounce[identity]=now
            if len(self._debounce)>10000:
                self._debounce={k:v for k,v in self._debounce.items() if now-v<60}
        with self.relay.db() as db:
            rows=db.execute('SELECT token,environment FROM push_tokens WHERE identity=? AND kind=?',(identity,kind)).fetchall()
        if not rows:
            return False
        async with self._lock:
            if self._client is None:
                import httpx
                self._client=httpx.AsyncClient(http2=True,timeout=10)
        success=False
        for row in rows:
            try:
                host='api.sandbox.push.apple.com' if row['environment']=='sandbox' else 'api.push.apple.com'
                payload={'aps':{'alert':{'title':'VO1D','body':'Новое сообщение'},'sound':'default','content-available':1}}
                expiration=int(time.time())+3600
                if kind=='voip':
                    if not call:
                        continue
                    payload={'aps':{'content-available':1},'callID':call['id'],'from':call['from']}
                    expiration=int(time.time())+45
                response=await self._client.post(f'https://{host}/3/device/{row["token"]}',
                    json=payload,headers={
                        'authorization':'bearer '+self.jwt(),
                        'apns-topic':self.topic+('.voip' if kind=='voip' else ''),
                        'apns-push-type':kind,'apns-priority':'10',
                        'apns-expiration':str(expiration),
                        **({'apns-collapse-id':'mailbox'} if kind=='alert' else {})
                    })
                if response.status_code==200:
                    success=True
                elif response.status_code in (400,410):
                    reason=response.json().get('reason','')
                    if reason in ('BadDeviceToken','Unregistered','DeviceTokenNotForTopic'):
                        with self.relay.db() as db:
                            db.execute('DELETE FROM push_tokens WHERE identity=? AND token=? AND kind=?',(identity,row['token'],kind))
            except Exception:
                # Never log payloads, device tokens, keys or provider responses.
                pass
        return success

    async def close(self):
        if self._client is not None:
            await self._client.aclose()
