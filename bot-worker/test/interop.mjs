import fs from 'node:fs';
import assert from 'node:assert/strict';
import {randomBytes,randomUUID} from 'node:crypto';
import {makeIdentity,identityCard,encryptExport,decryptExport,b64,json,now} from '../src/crypto.mjs';
import {createSnapshot,publication,encrypt,decrypt} from '../src/signal.mjs';

const filename=new URL('../../ios/VO1DMessengerTests/Resources/signal-interop.json',import.meta.url);
if(process.argv[2]==='verify') {
  const fixture=JSON.parse(fs.readFileSync(filename)), response=JSON.parse(fs.readFileSync(process.argv[3]));
  const opened=await decrypt(response.packet,fixture.recipientCard,fixture.senderState);
  assert.equal(opened.clear.toString(),'Swift reply to official Node SDK');
  const returned=decryptExport(Buffer.from(response.workerExport,'base64'),'interop password 123');
  assert.equal(returned.bot.card.id,fixture.recipientCard.id);
  assert.deepEqual(returned.state.extended.signal,response.recipientState);
  console.log('Swift/Node libsignal and encrypted worker transfer interoperable');
} else {
  const sender=makeIdentity(),recipient=makeIdentity(), senderCard=identityCard(sender),recipientCard=identityCard(recipient);
  const recipientState=publication(createSnapshot(),recipient,2), encrypted=await encrypt(Buffer.from('Official Node SDK to Swift'),recipientCard,sender,createSnapshot(),recipientState.pendingPublication.bundles[0]);
  const bot={card:recipientCard,keyProfileID:randomUUID(),server:'https://relay.invalid',name:'Interop Bot',username:'interop_bot',token:randomBytes(32).toString('base64url'),commands:{start:'Hello'},registered:true,settingsPending:false,enabled:true,externalExecution:true};
  const state={nickname:'Interop Bot',server:bot.server,onboarded:false,appLock:false,readReceipts:true,contacts:[],rooms:[],messages:[],outbox:[],processed:[],extended:{signal:recipientState,ownMailboxes:[]}};
  const payload={version:1,bot,identity:recipient,state,executorID:randomBytes(32).toString('base64url')};
  fs.mkdirSync(new URL('../../ios/VO1DMessengerTests/Resources/',import.meta.url),{recursive:true});
  fs.writeFileSync(filename,json({sender,senderCard,recipient,recipientCard,senderState:encrypted.state,recipientState,packet:JSON.parse(encrypted.packet),workerExport:b64(encryptExport(payload,'interop password 123'))}));
  console.log('Generated disposable cross-SDK test fixture (never production keys)');
}
