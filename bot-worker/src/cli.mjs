import fs from 'node:fs';
import {spawn} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
import {EncryptedFile,RelayClient,Worker} from './worker.mjs';

export function subprocessHandler(executable) {
  return input=>new Promise((resolve,reject)=>{
    // This is an explicitly configured trusted endpoint program, never a chat command.
    const child=spawn(executable,[],{shell:false,stdio:['pipe','pipe','ignore'],windowsHide:true,env:{PATH:process.env.PATH}});
    let data=Buffer.alloc(0), settled=false;
    const fail=()=>{if(settled)return;settled=true;clearTimeout(timer);child.kill();const error=Error('Bot handler failed');error.handlerFailure=true;reject(error);};
    const timer=setTimeout(fail,5000); child.on('error',fail);
    child.stdout.on('data',chunk=>{data=Buffer.concat([data,chunk]);if(data.length>20000)fail();});
    child.on('close',code=>{if(settled)return;if(code!==0)return fail();try{const reply=JSON.parse(data);if(reply.text!==null && (typeof reply.text!=='string' || [...reply.text].length>4000))return fail();settled=true;clearTimeout(timer);resolve(reply.text);}catch{fail();}});
    child.stdin.on('error',fail); child.stdin.end(JSON.stringify(input));
  });
}
export async function main(args=process.argv.slice(2)) {
  if(args.length!==2 || args[0]!=='--vault') throw Error('Usage: node src/cli.mjs --vault /private/bot.vo1dbot');
  const passwordFile=process.env.VO1D_BOT_PASSWORD_FILE;
  if(!passwordFile) throw Error('Set VO1D_BOT_PASSWORD_FILE to a protected password file');
  const stat=fs.lstatSync(passwordFile);
  if(!stat.isFile() || stat.isSymbolicLink() || stat.size>2048 || (process.platform!=='win32' && (stat.mode&0o077)!==0)) throw Error('Password file must be private (chmod 600)');
  const password=fs.readFileSync(passwordFile,'utf8').replace(/\r?\n$/,''), vault=new EncryptedFile(args[1],password);
  vault.acquire();
  try {
    const payload=vault.read(), client=new RelayClient(payload.bot,payload.executorID,{proxy:process.env.VO1D_BOT_SOCKS_PROXY});
    const worker=new Worker(payload,next=>vault.save(next),client,process.env.VO1D_BOT_HANDLER ? subprocessHandler(process.env.VO1D_BOT_HANDLER) : undefined);
    let stopped=false;process.once('SIGINT',()=>{stopped=true;});process.once('SIGTERM',()=>{stopped=true;});
    console.log('VO1D bot worker started; payloads and credentials are not logged');
    let retry=0;
    while(!stopped) {
      try {await worker.tick();retry=0;} catch(error) {
        if([401,403,409].includes(error.status)) throw Error('Worker stopped: credential revoked or another executor selected');
        retry=Math.min(6,retry+1);console.error('Worker retry pending; encrypted state retained');
      }
      await new Promise(resolve=>setTimeout(resolve,retry ? Math.min(60000,1000*2**retry) : 3000));
    }
  } finally {vault.close();}
}
if(process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href) main().catch(()=>{console.error('VO1D bot worker stopped; check configuration and protected state');process.exitCode=1;});
