// Test-only loopback endpoint. Production CLI never permits cleartext relays.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {randomBytes,randomUUID} from 'node:crypto';
import {makeIdentity,identityCard,encryptExport,decryptExport,json,sign,hash,now,sealEnvelope,openEnvelope} from '../src/crypto.mjs';
import {createSnapshot,publication,encrypt,decrypt} from '../src/signal.mjs';
import {EncryptedFile,RelayClient,Worker} from '../src/worker.mjs';

if(process.argv[2]==='init') {
  const owner=process.argv[3], server=process.argv[4], identity=makeIdentity(), card=identityCard(identity), alice=makeIdentity(), aliceCard=identityCard(alice);
  const bot={card,keyProfileID:randomUUID(),server,name:'HTTP Bot',username:'http_test_bot',token:randomBytes(32).toString('base64url'),commands:{start:'Encrypted HTTP reply'},registered:true,enabled:true,settingsPending:false,externalExecution:true};
  const signal=publication(createSnapshot(),identity,2), state={contacts:[],rooms:[],messages:[],outbox:[],processed:[],extended:{signal,ownMailboxes:[],privateLinks:[]}}, executorID=randomBytes(32).toString('base64url');
  const creation={card,name:bot.name,username:bot.username,token:bot.token,ownershipSignature:sign(identity,Buffer.from(`VO1D-BOT-CREATE-1\n${owner}\n${card.id}\n${bot.username}\n${bot.name}\n${hash(bot.token)}`))};
  const room={id:'dm:'+ [aliceCard.id,card.id].sort().join(':'),title:'',members:[aliceCard,card],creator:'',isGroup:false,createdAt:now(),pinned:false,archived:false,muted:false,unread:0,draft:'',disappearingSeconds:0};
  const event={id:randomUUID(),kind:'message',room,message:{id:randomUUID(),roomID:room.id,sender:aliceCard.id,text:'/start',createdAt:now()},senderName:'Alice',at:now()};
  const encrypted=await encrypt(json(event),card,alice,createSnapshot(),signal.pendingPublication.bundles[0]);
  console.log(JSON.stringify({creation,payload:{version:1,bot,identity,state,executorID},alice,aliceCard,aliceState:encrypted.state,envelope:sealEnvelope(encrypted.packet,alice,card,event.id)}));
} else if(process.argv[2]==='tick') {
  const password='integration password 123', vault=new EncryptedFile(process.argv[3],password);
  vault.acquire();try{
    const payload=vault.read(), client=new RelayClient(payload.bot,payload.executorID,{allowLoopback:true,instance:process.argv[4]});
    const worker=new Worker(payload,next=>vault.save(next),client);await worker.tick();console.log(JSON.stringify({processed:worker.payload.state.processed.length,pending:worker.payload.state.outbox.length}));
  }finally{vault.close();}
} else if(process.argv[2]==='verify') {
  const input=JSON.parse(fs.readFileSync(process.argv[3])), opened=openEnvelope(input.reply,input.alice,input.botCard), decrypted=await decrypt(JSON.parse(opened.packet),input.botCard,input.aliceState);
  assert.equal(JSON.parse(decrypted.clear).message.text,'Encrypted HTTP reply');console.log('Real HTTP bot reply decrypted');
} else {
  const input=JSON.parse(fs.readFileSync(process.argv[3]));fs.writeFileSync(process.argv[4],encryptExport(input,'integration password 123'),{mode:0o600});
}
