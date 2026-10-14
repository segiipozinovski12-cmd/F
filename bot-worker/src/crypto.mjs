import * as c from 'node:crypto';
export const now = () => Math.floor(Date.now() / 1000);
export const json = value => Buffer.from(JSON.stringify(value));
export const b64 = value => Buffer.from(value).toString('base64');
export const hash = value => c.createHash('sha256').update(value).digest('hex');
export function decode(value, size) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw Error('Invalid base64');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.toString('base64') !== value || (size !== undefined && bytes.length !== size)) throw Error('Invalid bytes');
  return bytes;
}
function privateKey(bytes, type) {
  return c.createPrivateKey({key: Buffer.concat([Buffer.from(type === 'ed' ? '302e020100300506032b657004220420' : '302e020100300506032b656e04220420', 'hex'), bytes]), format: 'der', type: 'pkcs8'});
}
function publicKey(bytes, type) {
  return c.createPublicKey({key: Buffer.concat([Buffer.from(type === 'ed' ? '302a300506032b6570032100' : '302a300506032b656e032100', 'hex'), bytes]), format: 'der', type: 'spki'});
}
const rawPublic = key => c.createPublicKey(key).export({type: 'spki', format: 'der'}).subarray(-32);
export const sign = (identity, bytes) => b64(c.sign(null, bytes, privateKey(decode(identity.signing, 32), 'ed')));
export function verify(card, bytes, signature) {
  if (!c.verify(null, bytes, publicKey(decode(card.signingKey, 32), 'ed'), decode(signature, 64))) throw Error('Invalid signature');
}
const cardBytes = card => Buffer.from(`VO1D-CARD-1\n${card.id}\n${card.signingKey}\n${card.agreementKey}`);
export function validateCard(card) {
  if (!card || hash(decode(card.signingKey, 32)) !== card.id) throw Error('Invalid contact');
  // Node/OpenSSL rejects non-contributory X25519 keys at key agreement.
  c.diffieHellman({privateKey: c.generateKeyPairSync('x25519').privateKey, publicKey: publicKey(decode(card.agreementKey, 32), 'x')});
  verify(card, cardBytes(card), card.binding); return card;
}
export function identityCard(identity) {
  decode(identity.storage, 32);
  const signingKey = b64(rawPublic(privateKey(decode(identity.signing, 32), 'ed')));
  const card = {id: hash(decode(signingKey)), signingKey, agreementKey: b64(rawPublic(privateKey(decode(identity.agreement, 32), 'x')))};
  card.binding = sign(identity, cardBytes(card)); return card;
}
export function makeIdentity() {
  return {signing: b64(c.randomBytes(32)), agreement: b64(c.randomBytes(32)), storage: b64(c.randomBytes(32))};
}
export function seal(clear, key, aad) {
  const nonce = c.randomBytes(12), cipher = c.createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(aad);
  return Buffer.concat([nonce, cipher.update(clear), cipher.final(), cipher.getAuthTag()]);
}
export function open(combined, key, aad) {
  if (combined.length < 28) throw Error('Invalid ciphertext');
  const cipher = c.createDecipheriv('aes-256-gcm', key, combined.subarray(0,12));
  cipher.setAAD(aad); cipher.setAuthTag(combined.subarray(-16));
  return Buffer.concat([cipher.update(combined.subarray(12,-16)), cipher.final()]);
}
export function passwordKey(password, salt, rounds) {
  if (typeof password !== 'string' || [...password].length < 12 || Buffer.byteLength(password) > 1024 || salt.length !== 16 || rounds !== 600000) throw Error('Unsupported password envelope');
  return c.pbkdf2Sync(password, salt, rounds, 32, 'sha256');
}
export const FORMAT = 'VO1D-BOT-WORKER-1';
export function encryptExport(payload, password) {
  const salt = c.randomBytes(16), key = passwordKey(password, salt, 600000);
  try { return json({format: FORMAT, rounds: 600000, salt: b64(salt), ciphertext: b64(seal(json(payload), key, Buffer.from(FORMAT)))}); }
  finally { key.fill(0); }
}
export function decryptExport(data, password) {
  if (data.length > 24*1024*1024) throw Error('Worker file too large');
  const envelope = JSON.parse(data);
  if (envelope.format !== FORMAT) throw Error('Unsupported worker format');
  const key = passwordKey(password, decode(envelope.salt,16), envelope.rounds);
  try { return JSON.parse(open(decode(envelope.ciphertext), key, Buffer.from(FORMAT))); }
  finally { key.fill(0); }
}
export function validatePayload(payload) {
  if (payload.version !== 1 || !/^[A-Za-z0-9_-]{43}$/.test(payload.executorID ?? '') || !payload.state?.extended?.signal || !payload.bot?.card) throw Error('Invalid worker payload');
  const card = identityCard(payload.identity); validateCard(payload.bot.card);
  if (JSON.stringify(card) !== JSON.stringify({id:payload.bot.card.id, signingKey:payload.bot.card.signingKey, agreementKey:payload.bot.card.agreementKey, binding:payload.bot.card.binding})) throw Error('Worker identity mismatch');
  if (!/^[A-Za-z0-9_-]{43}$/.test(payload.bot.token) || !payload.bot.registered || payload.state.managedBots?.length || payload.state.pendingReports?.length || (payload.state.outbox?.length ?? 0) > 1000 || (payload.state.contacts?.length ?? 0) > 1000) throw Error('Invalid bot state');
  if (json(payload).length > 16*1024*1024) throw Error('Worker state too large');
  for(const [records,limit] of [[payload.state.contacts,1000],[payload.state.outbox,1000],[payload.state.processed,5000],[payload.state.extended.ownMailboxes,512]]) {
    if(!Array.isArray(records) || records.length>limit) throw Error('Invalid worker collection');
  }
  const signal=payload.state.extended.signal;
  if (!Number.isInteger(signal.registration) || signal.registration<1 || signal.registration>0xffffffff || !Number.isInteger(signal.nextKey) || signal.nextKey<1 || signal.nextKey>0xffffffff) throw Error('Invalid Signal counters');
  for(const [name,limit] of [['prekeys',512],['kyberKeys',512],['signedKeys',512],['sessions',1000],['trusted',1000]]) {
    const records=signal[name]; if(!records || typeof records!=='object' || Array.isArray(records) || Object.keys(records).length>limit) throw Error('Invalid Signal store');
  }
  if(signal.pendingPublication && (!Array.isArray(signal.pendingPublication.bundles) || signal.pendingPublication.bundles.length<1 || signal.pendingPublication.bundles.length>48)) throw Error('Invalid Signal publication size');
  return payload;
}
const header = e => Buffer.from(e.mailbox ? `VO1D-OPAQUE-2\n${e.id}\n${e.mailbox}\n${e.ephemeralKey}\n${e.salt}\n${e.expiresAt}` : `VO1D-ENVELOPE-1\n${e.id}\n${e.sender}\n${e.recipient}\n${e.ephemeralKey}\n${e.salt}\n${e.expiresAt}`);
const buckets = [2048,8192,32768,131072,524288,2097152,5242880];
export function validateRoute(route) {
  if (!/^[A-Za-z0-9_-]{43}$/.test(route?.id ?? '') || !/^[A-Za-z0-9_-]{43}$/.test(route?.writeToken ?? '') || !Number.isInteger(route.expiresAt) || route.expiresAt <= now() || route.expiresAt > now()+31*86400) throw Error('Invalid mailbox');
}
function keyFor(e, privateBytes, publicBytes) {
  const shared = c.diffieHellman({privateKey: privateKey(privateBytes,'x'), publicKey: publicKey(publicBytes,'x')});
  return c.hkdfSync('sha256', shared, decode(e.salt,32), header(e), 32);
}
export function sealEnvelope(packet, identity, target, id, expiry, route) {
  validateCard(target); const ephemeral = c.randomBytes(32), own = identityCard(identity);
  const e = {id, ...(route ? {mailbox:route.id} : {sender:own.id,recipient:target.id}), ephemeralKey:b64(rawPublic(privateKey(ephemeral,'x'))),salt:b64(c.randomBytes(32)),expiresAt:Math.floor(Math.min(now()+7*86400, expiry ?? Infinity, route?.expiresAt ?? Infinity))};
  let clear = packet;
  if (route) {
    validateRoute(route);
    const signed = Buffer.concat([header(e), Buffer.from(`\n${target.id}\n`), packet]);
    const content = json({sender:own,recipient:target.id,packet:b64(packet),signature:sign(identity,signed)});
    const bucket = buckets.find(n=> n >= content.length+4); if (!bucket) throw Error('Packet too large');
    clear = c.randomBytes(bucket); clear.writeUInt32BE(content.length); content.copy(clear,4);
  }
  const combined = seal(clear,keyFor(e,ephemeral,decode(target.agreementKey,32)),header(e)); e.ciphertext = b64(combined);
  if (route) e.writeToken = route.writeToken;
  else e.signature = sign(identity,Buffer.concat([header(e),Buffer.from('\n'),combined]));
  return e;
}
export function openEnvelope(e, identity, sender, mailbox) {
  if (!Number.isInteger(e.expiresAt) || e.expiresAt <= now()) throw Error('Expired envelope');
  const combined = decode(e.ciphertext), own = identityCard(identity);
  if (!mailbox) {
    validateCard(sender);
    if (e.sender !== sender.id || e.recipient !== own.id) throw Error('Wrong recipient');
    verify(sender,Buffer.concat([header(e),Buffer.from('\n'),combined]),e.signature);
  } else if (e.mailbox !== mailbox.address.id || !buckets.includes(combined.length-28)) throw Error('Wrong private mailbox');
  const clear = open(combined,keyFor(e,decode(identity.agreement,32),decode(e.ephemeralKey,32)),header(e));
  if (!mailbox) return {sender,packet:clear};
  const size = clear.readUInt32BE(0); if (size < 1 || size > clear.length-4) throw Error('Invalid padding');
  const content = JSON.parse(clear.subarray(4,4+size)); validateCard(content.sender);
  if (content.recipient !== own.id || (mailbox.peerID && content.sender.id !== mailbox.peerID)) throw Error('Wrong private participant');
  const packet = decode(content.packet); verify(content.sender,Buffer.concat([header(e),Buffer.from(`\n${content.recipient}\n`),packet]),content.signature);
  return {sender:content.sender,packet};
}
