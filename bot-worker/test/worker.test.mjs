import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {randomBytes,randomUUID} from 'node:crypto';
import {makeIdentity,identityCard,encryptExport,decryptExport,validatePayload,json,b64,now,sealEnvelope,openEnvelope} from '../src/crypto.mjs';
import {createSnapshot,publication,encrypt,decrypt} from '../src/signal.mjs';
import {EncryptedFile,Worker,RelayClient,commandReply,HTTPFailure} from '../src/worker.mjs';

function fixture() {
  const identity=makeIdentity(), card=identityCard(identity), signal=publication(createSnapshot(),identity,2);
  const bot={card,keyProfileID:randomUUID(),server:'https://relay.invalid',name:'Test Bot',username:'test_bot',token:randomBytes(32).toString('base64url'),commands:{start:'Hello'},registered:true,settingsPending:false,enabled:true,externalExecution:true};
  const state={contacts:[],rooms:[],messages:[],outbox:[],processed:[],extended:{signal,ownMailboxes:[],privateLinks:[]}};
  return {version:1,identity,bot,state,executorID:randomBytes(32).toString('base64url')};
}
async function inbound(payload) {
  const alice=makeIdentity(), card=identityCard(alice), room={id:'dm:'+ [card.id,payload.bot.card.id].sort().join(':'),title:'',members:[card,payload.bot.card],creator:'',isGroup:false,createdAt:now(),pinned:false,archived:false,muted:false,unread:0,draft:'',disappearingSeconds:0};
  const event={id:randomUUID(),kind:'message',room,message:{id:randomUUID(),roomID:room.id,sender:card.id,text:'/start',createdAt:now()},senderName:'Alice',at:now()};
  const encrypted=await encrypt(json(event),payload.bot.card,alice,createSnapshot(),payload.state.extended.signal.pendingPublication.bundles[0]);
  return {alice,card,event,...encrypted};
}
test('official libsignal PQXDH records survive restart, bidirectional ratchet and replay rejection',async()=>{
  const p=fixture(), a=await inbound(p), opened=await decrypt(JSON.parse(a.packet),a.card,p.state.extended.signal);
  assert.equal(JSON.parse(opened.clear).message.text,'/start');
  const response=await encrypt(Buffer.from('reply'),a.card,p.identity,JSON.parse(JSON.stringify(opened.state)));
  const result=await decrypt(JSON.parse(response.packet),p.bot.card,a.state);
  assert.equal(result.clear.toString(),'reply');
  await assert.rejects(()=>decrypt(JSON.parse(a.packet),a.card,opened.state));
  assert.equal(Object.keys(p.state.extended.signal.prekeys).length,2); // disposable stores
  assert.equal(Object.keys(opened.state.prekeys).length,1);
  assert.equal(Object.keys(opened.state.kyberKeys).length,1);
});
test('identity binding, forged prekey signatures and unsupported packet types fail closed',async()=>{
  const p=fixture(), a=await inbound(p), packet=JSON.parse(a.packet);
  packet.identityBinding=b64(Buffer.alloc(64)); await assert.rejects(()=>decrypt(packet,a.card,p.state.extended.signal));
  const bad=structuredClone(p.state.extended.signal.pendingPublication.bundles[0]); bad.signature=b64(Buffer.alloc(64));
  await assert.rejects(()=>encrypt(Buffer.from('x'),p.bot.card,a.alice,createSnapshot(),bad));
  const unsupported=JSON.parse(a.packet);unsupported.type=8;await assert.rejects(()=>decrypt(unsupported,a.card,p.state.extended.signal));
});
test('normal and opaque envelopes are authenticated and reject tampering and wrong recipients',()=>{
  const a=makeIdentity(), b=makeIdentity(), ac=identityCard(a),bc=identityCard(b), payload=Buffer.from('sealed');
  const e=sealEnvelope(payload,a,bc,randomUUID());assert.equal(openEnvelope(e,b,ac).packet.toString(),'sealed');
  const bad={...e,ciphertext:b64(Buffer.from(e.ciphertext,'base64').map((v,i)=>i===16 ? v^1 : v))};assert.throws(()=>openEnvelope(bad,b,ac));
  assert.throws(()=>openEnvelope(e,a,ac));
  const route={id:randomBytes(32).toString('base64url'),writeToken:randomBytes(32).toString('base64url'),expiresAt:now()+86400};
  const opaque=sealEnvelope(payload,a,bc,randomUUID(),undefined,route), mailbox={address:route,peerID:ac.id};
  assert.equal(openEnvelope(opaque,b,undefined,mailbox).packet.toString(),'sealed');assert.throws(()=>openEnvelope(opaque,b,undefined,{address:route,peerID:bc.id}));
});
test('encrypted export retains exact bot ratchet and denies wrong password and resource bombs',()=>{
  const p=fixture(), data=encryptExport(p,'long password for bot');assert.deepEqual(validatePayload(decryptExport(data,'long password for bot')),p);
  assert.throws(()=>decryptExport(data,'incorrect password'));assert.throws(()=>encryptExport(p,'short'));
  const bomb=JSON.parse(data);bomb.rounds=0xffffffff;assert.throws(()=>decryptExport(json(bomb),'long password for bot'));
  const tampered=JSON.parse(data);tampered.ciphertext=b64(Buffer.alloc(40));assert.throws(()=>decryptExport(json(tampered),'long password for bot'));
  p.identity=makeIdentity();assert.throws(()=>validatePayload(p));
});
test('exclusive file lock and atomic encrypted saves survive a new process',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'vo1d-worker-')), filename=path.join(dir,'test.vo1dbot'), password='long password for bot', p=fixture();
  fs.writeFileSync(filename,encryptExport(p,password),{mode:0o600});
  const first=new EncryptedFile(filename,password), second=new EncryptedFile(filename,password);
  try { first.acquire();assert.throws(()=>second.acquire());const next=first.read();next.state.processed=['saved'];first.save(next);assert.deepEqual(first.read().state.processed,['saved']);first.close();second.acquire();assert.deepEqual(second.read().state.processed,['saved']); }
  finally{first.close();second.close();fs.rmSync(dir,{recursive:true,force:true});}
});
test('bot commits ratchet and exact reply together; failed storage never acknowledges',async()=>{
  const p=fixture(), a=await inbound(p);let writes=0;
  const worker=new Worker(p,()=>{writes++;throw Error('Disk full');},{});
  await assert.rejects(()=>worker.receive(a.packet,a.card,'packet-id'),/Disk full/);
  assert.equal(writes,1);assert.deepEqual(worker.payload,p);
  worker.persist=()=>{};await worker.receive(a.packet,a.card,'packet-id');
  assert.equal(worker.payload.state.outbox.length,1);assert.deepEqual(worker.payload.state.processed,['packet-id']);
  const opened=openEnvelope(worker.payload.state.outbox[0].envelope,a.alice,p.bot.card), reply=await decrypt(JSON.parse(opened.packet),p.bot.card,a.state);
  assert.equal(JSON.parse(reply.clear).message.text,'Hello');
});
test('corrupt packets are durably rejected and do not advance Signal state',async()=>{
  const p=fixture(), worker=new Worker(p,()=>{},{}), a=makeIdentity();await worker.receive(Buffer.from('{}'),identityCard(a),'bad');
  assert.equal(worker.payload.state.rejectedBotPackets,1);assert.deepEqual(worker.payload.state.extended.signal,p.state.extended.signal);assert.deepEqual(worker.payload.state.processed,['bad']);
});
test('outbox retry retains ciphertext; stopped head cannot starve eligible work',async()=>{
  const p=fixture(), target=identityCard(makeIdentity()), e1=sealEnvelope(Buffer.from('one'),p.identity,target,randomUUID()), e2=sealEnvelope(Buffer.from('two'),p.identity,target,randomUUID());
  p.state.outbox=[{envelope:e1},{envelope:e2}];p.state.deliveryRetryState={[e1.id+e1.recipient]:{nextAttempt:now()+1000}};
  let sent=[];const client={lease:async()=>{},request:async(route,m,e)=>{sent.push(e);throw new HTTPFailure(503);}};
  const worker=new Worker(p,()=>{},client);await worker.drain();assert.deepEqual(sent,[e2]);assert.deepEqual(worker.payload.state.outbox,p.state.outbox);
  client.request=async(route,m,e)=>{sent.push(e);};worker.payload.state.deliveryRetryState[e2.id+e2.recipient].nextAttempt=0;await worker.drain();assert.deepEqual(worker.payload.state.outbox,[{envelope:e1}]);
});
test('ordinary ACK occurs only after committed plaintext/ratchet/reply',async()=>{
  const p=fixture(), a=await inbound(p), envelope=sealEnvelope(a.packet,a.alice,p.bot.card,'accepted');let persisted=false,acks=[];
  const client={request:async(route,m,body)=>route.startsWith('/v1/identity/') ? a.card : (assert.equal(persisted,true),acks.push(body.ids),{ok:true})};
  const worker=new Worker(p,()=>{persisted=true;},client);await worker.batch([envelope]);assert.deepEqual(acks,[['accepted']]);
  const failing=new Worker(p,()=>{throw Error('No storage');},client);await assert.rejects(()=>failing.batch([envelope]));assert.equal(acks.length,1);
});
test('bot routing ignores groups, foreign senders, expired and ghost text',async()=>{
  const p=fixture(), a=await inbound(p);assert.equal(commandReply(a.event,a.card,p.bot.card,p.bot.commands),'Hello');
  for(const mutate of [e=>e.room.isGroup=true,e=>e.message.sender=p.bot.card.id,e=>e.message.expiresAt=0,e=>e.message.viewOnceSeconds=30,e=>e.room.id='forged']){const e=structuredClone(a.event);mutate(e);assert.equal(commandReply(e,a.card,p.bot.card,p.bot.commands),null);}
});
test('transport refuses cleartext, implicit onion DNS and credentials in URLs',()=>{
  const p=fixture();for(const server of ['http://example.com','https://user:pass@example.com','https://example.com/path','http://'+'a'.repeat(56)+'.onion']) assert.throws(()=>new RelayClient({...p.bot,server},p.executorID));
  assert.throws(()=>new RelayClient(p.bot,p.executorID,{proxy:'socks5://localhost:9050'}));
  assert.doesNotThrow(()=>new RelayClient({...p.bot,server:'http://'+'a'.repeat(56)+'.onion'},p.executorID,{proxy:'socks5h://localhost:9050'}));
});
