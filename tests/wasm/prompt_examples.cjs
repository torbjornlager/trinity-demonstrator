// Real engines and real worker threads; no demonstrator HTML, Vue or terminal.
'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {Worker:Thread}=require('node:worker_threads');
const runtime=require(path.join(path.resolve(process.argv[2]),'web/vendor/swi-wasm-node.js'));
const ROOT=path.resolve(process.argv[2]);
// Mirror the documented page script order before creating the runtime.
global.document={};require('node:vm').runInThisContext(fs.readFileSync(path.join(ROOT,'web/swi_wasm_actor_worker.js'),'utf8'));delete global.document;
const payloads=path.join(ROOT,'web/wasm');
assert.ok(payloads,'Run through tools/test.sh with pinned payload setup');
global.window={clearTimeout,setTimeout,location:{origin:'http://runtime.invalid'}};
class BrowserWorker {
  constructor(url) {
    assert.equal(url,'http://runtime.invalid/release/actor.js');
    this.thread=new Thread(`
      const {parentPort,workerData}=require('node:worker_threads');
      const fs=require('node:fs'),path=require('node:path');
      global.self={crypto:require('node:crypto').webcrypto,postMessage:m=>parentPort.postMessage(m),close:()=>{}};
      global.window=global.self;
      global.importScripts=url=>{
        if(url!=='http://runtime.invalid/release/engine.js')throw new Error('unexpected engine URL '+url);
        global.SWIPL=require(path.join(workerData.root,'web/swipl-bundle.js'));
      };
      const nativeFetch=global.fetch;
      global.fetch=async url=>{
        const base='http://runtime.invalid/release/prolog/';
        let text;
        if(url==='http://runtime.invalid/host/shared.pl')text='custom_fact(host_supplied).';
        else {
          if(!url.startsWith(base))return nativeFetch(url);
          text=fs.readFileSync(path.join(workerData.payloads,url.slice(base.length)),'utf8');
        }
        return {ok:true,text:async()=>text};
      };
      (0,eval)(fs.readFileSync(path.join(workerData.root,'web/swi_wasm_actor_worker.js'),'utf8'));
      parentPort.on('message',data=>self.onmessage({data}));
    `,{eval:true,workerData:{root:ROOT,payloads}});
    this.thread.on('message',data=>{if(this.onmessage)this.onmessage({data});});
    this.thread.on('error',error=>{if(this.onerror)this.onerror(error);});
  }
  postMessage(message){this.thread.postMessage(message);}
  terminate(){return this.thread.terminate();}
}
global.Worker=BrowserWorker;
function create(extra={}) {
  return runtime.create(Object.assign({
    workerUrl:'http://runtime.invalid/release/actor.js',engineUrl:'http://runtime.invalid/release/engine.js',
    prologBaseUrl:'http://runtime.invalid/release/prolog/',sharedDatabaseUrl:null
  },extra));
}
const wait=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{
 const cfg=JSON.parse(fs.readFileSync(process.argv[3])),events=[],rows=[];
 const node=create({onEvent:e=>{events.push(e);if(e.type==='output'&&String(e.data).includes('timeout_observed'))fetch(cfg.gate+'/release').catch(console.error);}});
 try {await node.open({source:cfg.source});let bindings={};
 for(const [name,original] of cfg.cases){
 if(['timeout-retry','callback-error'].includes(name))await fetch(cfg.gate+'/reset');
 if(['retry','callback-retry'].includes(name))await fetch(cfg.gate+'/release');
 const goal=original.replace(/\$([A-Z][A-Za-z0-9_]*)/g,(_,v)=>bindings[v]);
 let result;try{result=await node.query(goal,{limit:1,once:true});if(result.data?.[0])Object.assign(bindings,result.data[0]);}catch(e){result={error:String(e)}}
 rows.push({engine:'SWI-WASM',case:name,goal,result,passed:result.type==='success'&&(name!=='expert-agent'||events.some(e=>e.type==='output'&&String(e.data).includes('a good pet.')))});console.log('SWI-WASM',name,JSON.stringify(result));
 fs.writeFileSync(process.argv[4],JSON.stringify({rows,events},null,2));
 }
 }finally{node.dispose();await fetch(cfg.gate+'/release');}
})().catch(e=>{console.error(e);process.exitCode=1});
