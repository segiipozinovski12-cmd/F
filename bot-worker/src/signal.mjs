// Ratcheting and PQXDH are implemented by the pinned official Signal SDK.
import * as s from '@signalapp/libsignal-client';
import {randomInt} from 'node:crypto';
import {b64,decode,sign,verify,identityCard,validateCard,now,json} from './crypto.mjs';
const addressKey = a => `${a.name()}:${a.deviceId()}`;
export function createSnapshot() {
  return {identity:b64(s.IdentityKeyPair.generate().serialize()),registration:randomInt(1,16381),nextKey:1,prekeys:{},prekeyExpirations:{},signedKeys:{},kyberKeys:{},sessions:{},trusted:{},senderKeys:{}};
}
function stores(state) {
  const pair = s.IdentityKeyPair.deserialize(decode(state.identity));
  const sessions = new class extends s.SessionStore {
    async saveSession(a,r) { state.sessions[addressKey(a)] = b64(r.serialize()); }
    async getSession(a) { const v = state.sessions[addressKey(a)]; return v ? s.SessionRecord.deserialize(decode(v)) : null; }
    async getExistingSessions(as) { return Promise.all(as.map(async a=>{ const r=await this.getSession(a); if (!r) throw Error('Missing session'); return r; })); }
  }();
  const identities = new class extends s.IdentityKeyStore {
    async getIdentityKey() { return pair.privateKey; }
    async getLocalRegistrationId() { return state.registration; }
    async saveIdentity(a,k) { const old=state.trusted[addressKey(a)], value=b64(k.serialize()); if (old && old!==value) throw Error('Signal identity changed'); state.trusted[addressKey(a)]=value; return false; }
    async isTrustedIdentity(a,k) { const old=state.trusted[addressKey(a)]; return !old || old===b64(k.serialize()); }
    async getIdentity(a) { const v=state.trusted[addressKey(a)]; return v ? s.PublicKey.deserialize(decode(v)) : null; }
  }();
  const prekeys = new class extends s.PreKeyStore {
    async savePreKey(id,r) { state.prekeys[id]=b64(r.serialize()); }
    async getPreKey(id) { return s.PreKeyRecord.deserialize(decode(state.prekeys[id])); }
    async removePreKey(id) { delete state.prekeys[id]; delete state.prekeyExpirations[id]; }
  }();
  const signed = new class extends s.SignedPreKeyStore {
    async saveSignedPreKey(id,r) { state.signedKeys[id]=b64(r.serialize()); }
    async getSignedPreKey(id) { return s.SignedPreKeyRecord.deserialize(decode(state.signedKeys[id])); }
  }();
  const kyber = new class extends s.KyberPreKeyStore {
    async saveKyberPreKey(id,r) { state.kyberKeys[id]=b64(r.serialize()); }
    async getKyberPreKey(id) { return s.KyberPreKeyRecord.deserialize(decode(state.kyberKeys[id])); }
    async markKyberPreKeyUsed(id) { delete state.kyberKeys[id]; }
  }();
  return {pair,sessions,identities,prekeys,signed,kyber};
}
const bindingBytes = (key,owner)=>Buffer.from(`VO1D-SIGNAL-IDENTITY-2\n${owner}\n${key}`);
const bundleBytes = b=>Buffer.from(['VO1D-PREKEY-2',b.owner,b.identityKey,b.identityBinding,b.registrationId,b.deviceId,b.signedPrekeyId,b.signedPrekey,b.signedPrekeySignature,b.prekeyId,b.prekey,b.kyberPrekeyId,b.kyberPrekey,b.kyberPrekeySignature,b.expiresAt].join('\n'));
function validateBinding(key,binding,card) { validateCard(card); decode(key,33); verify(card,bindingBytes(key,card.id),binding); }
export function publication(input,identity,count=24) {
  if (!Number.isInteger(count) || count<1 || count>48) throw Error('Invalid prekey count');
  const state=structuredClone(input), {pair}=stores(state), owner=identityCard(identity).id;
  for (const [id,expiry] of Object.entries(state.prekeyExpirations)) if (expiry<=now()) { delete state.prekeys[id]; delete state.prekeyExpirations[id]; }
  for (const [id,value] of Object.entries(state.signedKeys)) if (s.SignedPreKeyRecord.deserialize(decode(value)).timestamp()+8*86400000<Date.now()) delete state.signedKeys[id];
  for (const [id,value] of Object.entries(state.kyberKeys)) if (s.KyberPreKeyRecord.deserialize(decode(value)).timestamp()+8*86400000<Date.now()) delete state.kyberKeys[id];
  if (!Number.isInteger(state.nextKey) || state.nextKey<1 || state.nextKey+count*2+1>0xffffffff) throw Error('Prekey counter exhausted');
  const signedID=state.nextKey++, signedKey=s.PrivateKey.generate(), signedSignature=pair.privateKey.sign(signedKey.getPublicKey().serialize());
  state.signedKeys[signedID]=b64(s.SignedPreKeyRecord.new(signedID,Date.now(),signedKey.getPublicKey(),signedKey,signedSignature).serialize());
  const identityKey=b64(pair.publicKey.serialize()), identityBinding=sign(identity,bindingBytes(identityKey,owner)), bundles=[];
  for(let i=0;i<count;i++) {
    const preID=state.nextKey++, kyberID=state.nextKey++, pre=s.PrivateKey.generate(), kyber=s.KEMKeyPair.generate(), kyberSignature=pair.privateKey.sign(kyber.getPublicKey().serialize());
    state.prekeys[preID]=b64(s.PreKeyRecord.new(preID,pre.getPublicKey(),pre).serialize()); state.prekeyExpirations[preID]=now()+8*86400;
    state.kyberKeys[kyberID]=b64(s.KyberPreKeyRecord.new(kyberID,Date.now(),kyber,kyberSignature).serialize());
    const b={owner,identityKey,identityBinding,registrationId:state.registration,deviceId:1,signedPrekeyId:signedID,signedPrekey:b64(signedKey.getPublicKey().serialize()),signedPrekeySignature:b64(signedSignature),prekeyId:preID,prekey:b64(pre.getPublicKey().serialize()),kyberPrekeyId:kyberID,kyberPrekey:b64(kyber.getPublicKey().serialize()),kyberPrekeySignature:b64(kyberSignature),expiresAt:now()+7*86400};
    b.signature=sign(identity,bundleBytes(b)); bundles.push(b);
  }
  if (Object.keys(state.prekeys).length>512 || Object.keys(state.kyberKeys).length>512) throw Error('Unconsumed prekey limit');
  state.pendingPublication={bundles}; return state;
}
export async function encrypt(clear,target,identity,input,bundle) {
  validateCard(target); const state=structuredClone(input), st=stores(state), address=s.ProtocolAddress.new(target.id,1);
  if (!(await st.sessions.getSession(address))?.hasCurrentState()) {
    if (!bundle || bundle.owner!==target.id || bundle.deviceId!==1 || bundle.expiresAt<=now() || bundle.expiresAt>now()+8*86400) throw Error('Missing valid prekey bundle');
    validateBinding(bundle.identityKey,bundle.identityBinding,target); verify(target,bundleBytes(bundle),bundle.signature);
    const b=s.PreKeyBundle.new(bundle.registrationId,1,bundle.prekeyId,s.PublicKey.deserialize(decode(bundle.prekey,33)),bundle.signedPrekeyId,s.PublicKey.deserialize(decode(bundle.signedPrekey,33)),decode(bundle.signedPrekeySignature,64),s.PublicKey.deserialize(decode(bundle.identityKey,33)),bundle.kyberPrekeyId,s.KEMPublicKey.deserialize(decode(bundle.kyberPrekey)),decode(bundle.kyberPrekeySignature,64));
    await s.processPreKeyBundle(b,address,st.sessions,st.identities);
  }
  const cipher=await s.signalEncrypt(clear,address,st.sessions,st.identities), identityKey=b64(st.pair.publicKey.serialize());
  return {state,packet:json({version:2,identityKey,identityBinding:sign(identity,bindingBytes(identityKey,identityCard(identity).id)),type:cipher.type(),ciphertext:b64(cipher.serialize())})};
}
export async function decrypt(packet,sender,input) {
  if (packet.version!==2 || decode(packet.ciphertext).length>7*1024*1024) throw Error('Invalid Signal packet');
  validateBinding(packet.identityKey,packet.identityBinding,sender);
  const state=structuredClone(input), st=stores(state), address=s.ProtocolAddress.new(sender.id,1), pinned=s.PublicKey.deserialize(decode(packet.identityKey,33));
  if (!await st.identities.isTrustedIdentity(address,pinned)) throw Error('Signal identity changed');
  let clear;
  if (packet.type===s.CiphertextMessageType.PreKey) clear=await s.signalDecryptPreKey(s.PreKeySignalMessage.deserialize(decode(packet.ciphertext)),address,st.sessions,st.identities,st.prekeys,st.signed,st.kyber);
  else if (packet.type===s.CiphertextMessageType.Whisper) clear=await s.signalDecrypt(s.SignalMessage.deserialize(decode(packet.ciphertext)),address,st.sessions,st.identities);
  else throw Error('Unsupported Signal packet');
  // The SDK saves the embedded identity. Reject a root-signed wrapper that
  // does not match it before committing any mutated record.
  if (state.trusted[addressKey(address)]!==packet.identityKey) throw Error('Signal wrapper identity mismatch');
  return {state,clear};
}
