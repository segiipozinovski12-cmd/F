'use strict';

const crypto = require('crypto');
const signal = require('@signalapp/libsignal-client');

function b64(buffer) { return Buffer.from(buffer).toString('base64'); }
function bytes(value) { return Buffer.from(value || '', 'base64'); }
function keyOf(address) { return `${address.name()}:${address.deviceId()}`; }

function freshSnapshot() {
  const pair = signal.IdentityKeyPair.generate();
  const random = crypto.randomBytes(2);
  const registration = (((random[0] << 8) | random[1]) % 16380) + 1;
  return {
    identity: b64(pair.serialize()),
    registration,
    nextKey: 1,
    prekeys: {},
    prekeyExpirations: {},
    signedKeys: {},
    kyberKeys: {},
    sessions: {},
    trusted: {},
    senderKeys: {},
    publishedAt: null
  };
}

function normalizeState(input) {
  const s = input || freshSnapshot();
  s.nextKey = Number(s.nextKey || 1);
  s.prekeys ||= {};
  s.prekeyExpirations ||= {};
  s.signedKeys ||= {};
  s.kyberKeys ||= {};
  s.sessions ||= {};
  s.trusted ||= {};
  s.senderKeys ||= {};
  return s;
}

class Sessions extends signal.SessionStore {
  constructor(state) { super(); this.state = state; }
  async saveSession(address, record) { this.state.sessions[keyOf(address)] = b64(record.serialize()); }
  async getSession(address) {
    const v = this.state.sessions[keyOf(address)];
    return v ? signal.SessionRecord.deserialize(bytes(v)) : null;
  }
  async getExistingSessions(addresses) {
    const out = [];
    for (const address of addresses) {
      const session = await this.getSession(address);
      if (!session) throw new Error('SESSION_MISSING');
      out.push(session);
    }
    return out;
  }
}

class Identities extends signal.IdentityKeyStore {
  constructor(state) { super(); this.state = state; }
  pair() { return signal.IdentityKeyPair.deserialize(bytes(this.state.identity)); }
  async getIdentityKey() { return this.pair().privateKey; }
  async getLocalRegistrationId() { return Number(this.state.registration); }
  async saveIdentity(address, key) {
    const k = keyOf(address);
    const value = b64(key.serialize());
    const old = this.state.trusted[k];
    if (old && old !== value) throw new Error('IDENTITY_CHANGED');
    this.state.trusted[k] = value;
    return !!old && old !== value;
  }
  async isTrustedIdentity(address, key) {
    const old = this.state.trusted[keyOf(address)];
    return !old || old === b64(key.serialize());
  }
  async getIdentity(address) {
    const old = this.state.trusted[keyOf(address)];
    return old ? signal.PublicKey.deserialize(bytes(old)) : null;
  }
}

class PreKeys extends signal.PreKeyStore {
  constructor(state) { super(); this.state = state; }
  async savePreKey(id, record) { this.state.prekeys[String(id)] = b64(record.serialize()); }
  async getPreKey(id) {
    const value = this.state.prekeys[String(id)];
    if (!value) throw new Error('PREKEY_MISSING');
    return signal.PreKeyRecord.deserialize(bytes(value));
  }
  async removePreKey(id) {
    delete this.state.prekeys[String(id)];
    delete this.state.prekeyExpirations[String(id)];
  }
}

class SignedKeys extends signal.SignedPreKeyStore {
  constructor(state) { super(); this.state = state; }
  async saveSignedPreKey(id, record) { this.state.signedKeys[String(id)] = b64(record.serialize()); }
  async getSignedPreKey(id) {
    const value = this.state.signedKeys[String(id)];
    if (!value) throw new Error('SIGNED_PREKEY_MISSING');
    return signal.SignedPreKeyRecord.deserialize(bytes(value));
  }
}

class KyberKeys extends signal.KyberPreKeyStore {
  constructor(state) { super(); this.state = state; }
  async saveKyberPreKey(id, record) { this.state.kyberKeys[String(id)] = b64(record.serialize()); }
  async getKyberPreKey(id) {
    const value = this.state.kyberKeys[String(id)];
    if (!value) throw new Error('KYBER_PREKEY_MISSING');
    return signal.KyberPreKeyRecord.deserialize(bytes(value));
  }
  async markKyberPreKeyUsed(id) { delete this.state.kyberKeys[String(id)]; }
}

class SenderKeys extends signal.SenderKeyStore {
  constructor(state) { super(); this.state = state; }
  key(address, distributionId) { return keyOf(address) + distributionId; }
  async saveSenderKey(address, distributionId, record) {
    this.state.senderKeys[this.key(address, distributionId)] = b64(record.serialize());
  }
  async getSenderKey(address, distributionId) {
    const value = this.state.senderKeys[this.key(address, distributionId)];
    return value ? signal.SenderKeyRecord.deserialize(bytes(value)) : null;
  }
}

function stores(state) {
  return {
    sessions: new Sessions(state),
    identities: new Identities(state),
    prekeys: new PreKeys(state),
    signed: new SignedKeys(state),
    kyber: new KyberKeys(state),
    sender: new SenderKeys(state)
  };
}

function publicBundle(bundle) {
  return signal.PreKeyBundle.new(
    Number(bundle.registrationId),
    Number(bundle.deviceId || 1),
    Number(bundle.prekeyId),
    signal.PublicKey.deserialize(bytes(bundle.prekey)),
    Number(bundle.signedPrekeyId),
    signal.PublicKey.deserialize(bytes(bundle.signedPrekey)),
    bytes(bundle.signedPrekeySignature),
    signal.PublicKey.deserialize(bytes(bundle.identityKey)),
    Number(bundle.kyberPrekeyId),
    signal.KEMPublicKey.deserialize(bytes(bundle.kyberPrekey)),
    bytes(bundle.kyberPrekeySignature)
  );
}

async function publication(input) {
  const state = normalizeState(input.snapshot);
  const count = Math.max(1, Math.min(48, Number(input.count || 24)));
  const now = Date.now();
  const nowSec = Math.floor(now / 1000);

  for (const [id, expiry] of Object.entries(state.prekeyExpirations))
    if (Number(expiry) <= nowSec) { delete state.prekeys[id]; delete state.prekeyExpirations[id]; }

  for (const [id, raw] of Object.entries(state.kyberKeys)) {
    try {
      const record = signal.KyberPreKeyRecord.deserialize(bytes(raw));
      if (record.timestamp() + 8 * 86400 * 1000 < now) delete state.kyberKeys[id];
    } catch { delete state.kyberKeys[id]; }
  }

  const pair = signal.IdentityKeyPair.deserialize(bytes(state.identity));
  const identityKey = b64(pair.publicKey.serialize());
  const signedPrekeyId = state.nextKey++;
  const signedPrivate = signal.PrivateKey.generate();
  const signedPublic = signedPrivate.getPublicKey();
  const signedPrekeySignature = pair.privateKey.sign(signedPublic.serialize());
  const signedRecord = signal.SignedPreKeyRecord.new(
    signedPrekeyId, now, signedPublic, signedPrivate, signedPrekeySignature
  );
  state.signedKeys[String(signedPrekeyId)] = b64(signedRecord.serialize());

  const bundles = [];
  for (let i = 0; i < count; i++) {
    const prekeyId = state.nextKey++;
    const kyberPrekeyId = state.nextKey++;

    const prePrivate = signal.PrivateKey.generate();
    const prePublic = prePrivate.getPublicKey();
    const preRecord = signal.PreKeyRecord.new(prekeyId, prePublic, prePrivate);
    state.prekeys[String(prekeyId)] = b64(preRecord.serialize());
    state.prekeyExpirations[String(prekeyId)] = nowSec + 8 * 86400;

    const kyberPair = signal.KEMKeyPair.generate();
    const kyberPublic = kyberPair.getPublicKey();
    const kyberSignature = pair.privateKey.sign(kyberPublic.serialize());
    const kyberRecord = signal.KyberPreKeyRecord.new(kyberPrekeyId, now, kyberPair, kyberSignature);
    state.kyberKeys[String(kyberPrekeyId)] = b64(kyberRecord.serialize());

    bundles.push({
      owner: input.owner,
      identityKey,
      registrationId: Number(state.registration),
      deviceId: 1,
      signedPrekeyId,
      signedPrekey: b64(signedPublic.serialize()),
      signedPrekeySignature: b64(signedPrekeySignature),
      prekeyId,
      prekey: b64(prePublic.serialize()),
      kyberPrekeyId,
      kyberPrekey: b64(kyberPublic.serialize()),
      kyberPrekeySignature: b64(kyberSignature),
      expiresAt: nowSec + 7 * 86400
    });
  }

  for (const [id, raw] of Object.entries(state.signedKeys)) {
    try {
      const record = signal.SignedPreKeyRecord.deserialize(bytes(raw));
      if (record.timestamp() + 8 * 86400 * 1000 < now) delete state.signedKeys[id];
    } catch { delete state.signedKeys[id]; }
  }

  if (Object.keys(state.prekeys).length > 512 || Object.keys(state.kyberKeys).length > 512)
    throw new Error('PREKEY_CAPACITY');

  state.publishedAt = nowSec;
  return { snapshot: state, bundles };
}

async function hasSession(input) {
  const state = normalizeState(input.snapshot);
  const s = stores(state);
  const address = signal.ProtocolAddress.new(input.targetId, 1);
  const session = await s.sessions.getSession(address);
  return { snapshot: state, hasSession: !!session && session.hasCurrentState() };
}

async function encrypt(input) {
  const state = normalizeState(input.snapshot);
  const s = stores(state);
  const address = signal.ProtocolAddress.new(input.targetId, 1);
  const existing = await s.sessions.getSession(address);

  if (!existing || !existing.hasCurrentState()) {
    if (!input.bundle) throw new Error('NO_SESSION');
    await signal.processPreKeyBundle(
      publicBundle(input.bundle), address, s.sessions, s.identities, new Date()
    );
  }

  const ciphertext = await signal.signalEncrypt(
    bytes(input.clear), address, s.sessions, s.identities, new Date()
  );
  const pair = signal.IdentityKeyPair.deserialize(bytes(state.identity));
  return {
    snapshot: state,
    packet: {
      version: 2,
      identityKey: b64(pair.publicKey.serialize()),
      type: ciphertext.type(),
      ciphertext: b64(ciphertext.serialize())
    }
  };
}

async function decrypt(input) {
  const state = normalizeState(input.snapshot);
  const s = stores(state);
  const address = signal.ProtocolAddress.new(input.senderId, 1);
  const pinned = signal.PublicKey.deserialize(bytes(input.packet.identityKey));
  const trustedKey = keyOf(address);
  const old = state.trusted[trustedKey];
  const pinnedRaw = b64(pinned.serialize());
  if (old && old !== pinnedRaw) throw new Error('IDENTITY_CHANGED');

  // Pin the packet identity before libsignal sees a PreKey message, so its internal
  // identity must match the outer-card-authenticated packet identity.
  state.trusted[trustedKey] = pinnedRaw;

  let clear;
  const cipher = bytes(input.packet.ciphertext);
  if (Number(input.packet.type) === signal.CiphertextMessageType.PreKey) {
    clear = await signal.signalDecryptPreKey(
      signal.PreKeySignalMessage.deserialize(cipher),
      address, s.sessions, s.identities, s.prekeys, s.signed, s.kyber
    );
  } else if (Number(input.packet.type) === signal.CiphertextMessageType.Whisper) {
    clear = await signal.signalDecrypt(
      signal.SignalMessage.deserialize(cipher),
      address, s.sessions, s.identities
    );
  } else {
    throw new Error('UNSUPPORTED_SIGNAL_TYPE');
  }
  return { snapshot: state, clear: b64(clear) };
}

async function handle(input) {
  switch (input.op) {
    case 'create': return { snapshot: freshSnapshot() };
    case 'publication': return publication(input);
    case 'hasSession': return hasSession(input);
    case 'encrypt': return encrypt(input);
    case 'decrypt': return decrypt(input);
    default: throw new Error('UNKNOWN_OPERATION');
  }
}

async function selfTest() {
  const a = freshSnapshot();
  const b = freshSnapshot();
  const pub = await publication({ snapshot: b, owner: 'b'.repeat(64), count: 1 });
  const bundle = pub.bundles[0];
  bundle.identityBinding = 'test';
  bundle.signature = 'test';
  const enc = await encrypt({ snapshot: a, targetId: 'b'.repeat(64), bundle, clear: b64(Buffer.from('VO1D-SIGNAL-SELFTEST')) });
  const dec = await decrypt({ snapshot: pub.snapshot, senderId: 'a'.repeat(64), packet: enc.packet });
  if (Buffer.from(dec.clear, 'base64').toString() !== 'VO1D-SIGNAL-SELFTEST') throw new Error('SELFTEST_MISMATCH');
  process.stdout.write('VO1D_SIGNAL_SELFTEST_OK\n');
}

if (process.argv.includes('--selftest')) {
  selfTest().catch(err => { process.stderr.write(String(err.stack || err) + '\n'); process.exit(1); });
} else {
  const readline = require('readline').createInterface({ input: process.stdin, crlfDelay: Infinity });
  readline.on('line', async line => {
    let id = null;
    try {
      const input = JSON.parse(line);
      id = input.id;
      const result = await handle(input);
      process.stdout.write(JSON.stringify({ id, ok: true, result }) + '\n');
    } catch (err) {
      process.stdout.write(JSON.stringify({ id, ok: false, error: String(err && err.message || err) }) + '\n');
    }
  });
}
