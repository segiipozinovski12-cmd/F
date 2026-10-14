import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import https from 'node:https';
import {randomBytes,randomUUID} from 'node:crypto';
import {SocksProxyAgent} from 'socks-proxy-agent';
import {decryptExport,encryptExport,validatePayload,identityCard,openEnvelope,sealEnvelope,json,now,validateRoute} from './crypto.mjs';
import {publication,decrypt,encrypt} from './signal.mjs';

export class HTTPFailure extends Error {
  constructor(status) { super(`Relay status ${status}`); this.status=status; }
}
export class RelayClient {
  constructor(bot,executor,{proxy,allowLoopback=false,instance=randomBytes(32).toString('base64url')}={}) {
    const url=new URL(bot.server), onion=/^[a-z2-7]{56}\.onion$/.test(url.hostname);
    const permittedHTTP=url.protocol==='http:' && (onion || (allowLoopback && ['localhost','127.0.0.1','[::1]'].includes(url.hostname)));
    if (url.username || url.password || url.search || url.hash || !['','/'].includes(url.pathname) || (url.protocol!=='https:' && !permittedHTTP)) throw Error('HTTPS relay required');
    if (onion && !proxy) throw Error('Onion requires explicit SOCKS5h route');
    if (proxy && !proxy.startsWith('socks5h://')) throw Error('SOCKS5h proxy required; no DNS or direct fallback');
    this.base=url; this.token=bot.token; this.executor=executor; this.instance=instance; this.agent=proxy ? new SocksProxyAgent(proxy,{timeout:20000}) : undefined;
  }
  async request(route,method='GET',body,capability) {
    const url=new URL(route,this.base), bytes=body===undefined ? undefined : json(body);
    const headers={'content-type':'application/json', ...(bytes ? {'content-length':bytes.length} : {}), ...(capability===undefined ? {authorization:`BotCapability ${this.token}`,'x-bot-executor':this.executor,'x-bot-instance':this.instance} : capability===null ? {} : {authorization:`Capability ${capability}`})};
    return new Promise((resolve,reject)=>{
      const req=(url.protocol==='https:' ? https : http).request(url,{method,headers,agent:this.agent},res=>{
        const chunks=[]; let size=0;
        res.on('data',chunk=>{size+=chunk.length; if(size>20*1024*1024) res.destroy(Error('Relay response too large')); else chunks.push(chunk);});
        res.on('error',reject); res.on('end',()=>{
          if(res.statusCode<200 || res.statusCode>=300) return reject(new HTTPFailure(res.statusCode)); // Redirects never followed.
          try { resolve(JSON.parse(Buffer.concat(chunks))); } catch { reject(Error('Invalid relay response')); }
        });
      });
      req.setTimeout(20000,()=>req.destroy(Error('Relay timeout'))); req.on('error',reject); req.end(bytes);
    });
  }
  async lease() { return this.request('/v2/bots/worker/lease','POST',{executor:this.executor,instance:this.instance}); }
}

export class EncryptedFile {
  constructor(filename,password) {
    this.filename=path.resolve(filename); this.password=password; this.lock=this.filename+'.worker-lock';
  }
  acquire() {
    this.fd=fs.openSync(this.lock,'wx',0o600);
    fs.writeFileSync(this.fd,json({pid:process.pid,created:now()})); fs.fsyncSync(this.fd);
  }
  read() {
    const stat=fs.lstatSync(this.filename);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size>24*1024*1024 || (process.platform!=='win32' && (stat.mode&0o077)!==0)) throw Error('Worker vault requires a private regular file (chmod 600)');
    return validatePayload(decryptExport(fs.readFileSync(this.filename),this.password));
  }
  save(payload) {
    validatePayload(payload); const bytes=encryptExport(payload,this.password), temp=this.filename+'.'+randomUUID()+'.tmp'; let fd;
    try {
      fd=fs.openSync(temp,'wx',0o600); fs.writeFileSync(fd,bytes); fs.fsyncSync(fd); fs.closeSync(fd); fd=undefined;
      fs.renameSync(temp,this.filename);
      if(process.platform!=='win32') { const dir=fs.openSync(path.dirname(this.filename),'r'); try{fs.fsyncSync(dir);}finally{fs.closeSync(dir);} }
    } finally { if(fd!==undefined) fs.closeSync(fd); if(fs.existsSync(temp)) fs.unlinkSync(temp); }
  }
  close() { if(this.fd!==undefined) { fs.closeSync(this.fd); fs.unlinkSync(this.lock); this.fd=undefined; } this.password=''; }
}

export function commandReply(event,sender,bot,commands) {
  const room=event.room, message=event.message, ids=[sender.id,bot.id].sort();
  if(event.kind!=='message' || !room || room.isGroup || room.members?.length!==2 || room.id!=='dm:'+ids.join(':') || room.members.map(x=>x.id).sort().join(':')!==ids.join(':') || !message || message.sender!==sender.id || message.roomID!==room.id || typeof message.text!=='string' || [...message.text].length>20000 || message.viewOnceSeconds!=null || (message.expiresAt??Infinity)<=now()) return null;
  const first=message.text.trim().split(/\s+/)[0].toLowerCase();
  if(!first.startsWith('/')) return 'Доступные команды: '+Object.keys(commands).sort().map(k=>'/'+k).join(', ');
  const name=first.slice(1).split('@')[0];
  if(name==='help') return Object.keys(commands).sort().map(k=>'/'+k).join('\n');
  return commands[name] ?? 'Команда не найдена. /help — список команд.';
}

export class Worker {
  constructor(payload,persist,client,handler) { this.payload=validatePayload(payload); this.persist=persist; this.client=client; this.handler=handler; }
  async commit(next) { await this.persist(next); this.payload=next; }
  async receive(packet,sender,envelopeID) {
    const original=this.payload, next=structuredClone(original), state=next.state;
    try {
      const decrypted=await decrypt(JSON.parse(packet),sender,state.extended.signal), event=JSON.parse(decrypted.clear);
      state.extended.signal=decrypted.state;
      const known=state.contacts.find(c=>c.card.id===sender.id);
      if(known && ['signingKey','agreementKey','binding'].some(k=>known.card[k]!==sender[k])) throw Error('Contact changed');
      if(!known) { if(state.contacts.length>=1000) throw Error('Bot contact limit'); state.contacts.push({card:sender,name:sender.id.slice(0,12),verified:false,blocked:false}); }
      let text=commandReply(event,sender,next.bot.card,next.bot.commands);
      // A handler sees only a validated direct message addressed to this bot.
      if(text!==null && this.handler) text=await this.handler({event,sender,bot:next.bot.card});
      if(text!==null) {
        if(typeof text!=='string' || [...text].length>4000 || Buffer.byteLength(text)>16000) throw Error('Invalid handler response');
        if(event.replyMailbox) validateRoute(event.replyMailbox);
        const reply={id:randomUUID(),roomID:event.room.id,sender:next.bot.card.id,text,createdAt:now(),expiresAt:event.message.expiresAt,replyTo:event.message.id,state:'queued',edited:false,reactions:{},readBy:[],deliveredTo:[]};
        const response={id:randomUUID(),kind:'message',room:event.room,message:reply,senderName:next.bot.name,at:now()};
        const encrypted=await encrypt(json(response),sender,next.identity,state.extended.signal); state.extended.signal=encrypted.state;
        const wire=sealEnvelope(encrypted.packet,next.identity,sender,response.id,reply.expiresAt,event.replyMailbox);
        const envelope=event.replyMailbox ? {id:wire.id,sender:next.bot.card.id,recipient:sender.id,ephemeralKey:'',salt:'',expiresAt:wire.expiresAt,ciphertext:'',signature:'',opaque:wire} : wire;
        state.outbox.push({envelope});
      }
    } catch(error) {
      // A failed plugin is transient: preserve the packet for retry, never ACK it.
      if(error.handlerFailure) throw error;
      await this.reject(envelopeID); return;
    }
    state.processed=[...state.processed,envelopeID].slice(-5000);
    // Persistence is deliberately outside the payload rejection block.
    await this.commit(next);
  }
  async reject(id) {
    const next=structuredClone(this.payload); next.state.processed=[...next.state.processed,id].slice(-5000); next.state.rejectedBotPackets=Math.min(1000000,(next.state.rejectedBotPackets??0)+1); await this.commit(next);
  }
  async drain() {
    let next=structuredClone(this.payload); next.state.outbox=next.state.outbox.filter(p=>p.envelope.expiresAt>now()); next.state.deliveryRetryState??={};
    const live=new Set(next.state.outbox.map(p=>p.envelope.id+p.envelope.recipient)); next.state.deliveryRetryState=Object.fromEntries(Object.entries(next.state.deliveryRetryState).filter(([id])=>live.has(id))); await this.commit(next);
    const ready=this.payload.state.outbox.filter(p=>(p.notBefore??0)<=now() && (this.payload.state.deliveryRetryState[p.envelope.id+p.envelope.recipient]?.nextAttempt??0)<=now()).slice(0,8);
    for(const pending of ready) {
      await this.client.lease(); const e=pending.envelope, id=e.id+e.recipient;
      try {
        if(e.opaque) { const {writeToken,...wire}=e.opaque; await this.client.request(`/v2/mailboxes/${wire.mailbox}/envelopes`,'POST',wire,writeToken); }
        else await this.client.request('/v1/envelopes','POST',e);
      } catch(error) {
        if([401,403,409].includes(error.status)) throw error;
        next=structuredClone(this.payload); const attempts=(next.state.deliveryRetryState[id]?.attempts??0)+1;
        next.state.deliveryRetryState[id]={id,detail:'Delivery deferred',attempts,nextAttempt:[400,404,413].includes(error.status) ? 253402300799 : now()+Math.min(300,2**Math.min(8,attempts))}; await this.commit(next); continue;
      }
      next=structuredClone(this.payload); next.state.outbox=next.state.outbox.filter(p=>p.envelope.id+p.envelope.recipient!==id); delete next.state.deliveryRetryState[id]; await this.commit(next);
    }
  }
  async maintainPrekeys() {
    let signal=this.payload.state.extended.signal;
    if(!signal.pendingPublication) {
      const count=await this.client.request('/v2/prekeys');
      if(count.available<12 || now()-(signal.publishedAt??0)>86400) {
        const next=structuredClone(this.payload); next.state.extended.signal=publication(signal,next.identity); await this.commit(next); signal=this.payload.state.extended.signal;
      }
    }
    if(signal.pendingPublication) {
      await this.client.request('/v2/prekeys','POST',signal.pendingPublication);
      const next=structuredClone(this.payload); next.state.extended.signal.pendingPublication=null; next.state.extended.signal.publishedAt=now(); await this.commit(next);
    }
  }
  async batch(envelopes,mailbox) {
    const ack=[];
    for(const e of envelopes) {
      if(this.payload.state.processed.includes(e.id) || e.expiresAt<=now()) {ack.push(e.id);continue;}
      if(this.payload.state.outbox.length>=100) break;
      let sender;
      if(!mailbox) sender=await this.client.request('/v1/identity/'+e.sender);
      let opened;
      try {opened=openEnvelope(e,this.payload.identity,sender,mailbox);} catch {await this.reject(e.id);ack.push(e.id);continue;}
      await this.receive(opened.packet,opened.sender,e.id); ack.push(e.id);
    }
    // Every received ratchet/reply or rejection has already been saved.
    if(ack.length) await this.client.request(mailbox ? `/v2/mailboxes/${mailbox.address.id}/ack` : '/v1/ack','POST',{ids:ack},mailbox?.readToken);
  }
  async flushPrivateLinks() {
    let next=structuredClone(this.payload);
    next.state.extended.privateLinks??=[];
    next.state.extended.privateLinks=next.state.extended.privateLinks.filter(r=>r.expiresAt>now());
    next.state.extended.ownMailboxes=next.state.extended.ownMailboxes.filter(m=>m.address.expiresAt>now());
    await this.commit(next);
    for(const record of this.payload.state.extended.privateLinks.filter(r=>(!r.published || r.revocationPending) && !r.stopped && (r.nextAttempt??0)<=now()).slice(0,8)) {
      const mailbox=this.payload.state.extended.ownMailboxes.find(m=>m.address.id===record.mailboxID); if(!mailbox) continue;
      await this.client.lease();
      try {
        if(record.revocationPending) await this.client.request(`/v2/mailboxes/${record.mailboxID}/invites/${record.token}`,'DELETE',undefined,mailbox.readToken);
        else await this.client.request(`/v2/mailboxes/${record.mailboxID}/invites`,'POST',{token:record.token,ciphertext:record.ciphertext,expiresAt:record.expiresAt},mailbox.readToken);
      } catch(error) {
        next=structuredClone(this.payload); const r=next.state.extended.privateLinks.find(r=>r.token===record.token);
        r.failure='Private invitation pending';r.nextAttempt=now()+60;r.stopped=[400,401,403,404,409,410,413].includes(error.status);await this.commit(next);continue;
      }
      next=structuredClone(this.payload);
      if(record.revocationPending) next.state.extended.privateLinks=next.state.extended.privateLinks.filter(r=>r.token!==record.token);
      else {const r=next.state.extended.privateLinks.find(r=>r.token===record.token);r.published=true;r.failure=null;r.nextAttempt=null;}
      await this.commit(next);
    }
  }
  async tick() {
    await this.client.lease(); await this.maintainPrekeys(); await this.flushPrivateLinks(); await this.drain();
    if(this.payload.state.outbox.length>=100) return;
    await this.client.lease(); const inbox=await this.client.request('/v1/inbox'); await this.batch(inbox.envelopes);
    const mailboxes=this.payload.state.extended.ownMailboxes.filter(m=>m.registered && m.address.expiresAt>now()), start=(this.payload.state.extended.privateInboxOffset??0)%Math.max(1,mailboxes.length);
    for(let offset=0;offset<Math.min(32,mailboxes.length);offset++) {
      await this.client.lease(); const position=(start+offset)%mailboxes.length, mailbox=mailboxes[position];
      const inbox=await this.client.request(`/v2/mailboxes/${mailbox.address.id}/inbox`,'GET',undefined,mailbox.readToken); await this.batch(inbox.envelopes,mailbox);
      const next=structuredClone(this.payload); next.state.extended.privateInboxOffset=(position+1)%mailboxes.length; await this.commit(next);
    }
    await this.drain();
  }
}
