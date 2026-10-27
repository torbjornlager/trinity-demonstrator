// Real engines and real worker threads; no demonstrator HTML, Vue or terminal.
'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {Worker:Thread}=require('node:worker_threads');
const runtime=require('../../web/vendor/swi-wasm-node.js');
const ROOT=path.resolve(__dirname,'../..');
const payloads=process.env.WP_WASM_SOURCE_DIR;
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
      global.fetch=async url=>{
        const base='http://runtime.invalid/release/prolog/';
        let text;
        if(url==='http://runtime.invalid/host/shared.pl')text='custom_fact(host_supplied).';
        else {
          if(!url.startsWith(base))throw new Error('unexpected payload URL '+url);
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
  const events=[];
  const node=create({onEvent:e=>events.push(e),onInput:()=> 'hello.'});
  const other=create();
  assert.notEqual(node.swiWasmActorWorkers,other.swiWasmActorWorkers);
  other.dispose();
  try {
    await node.open({source:'square(X,Y):-Y is X*X.'});
    let result=await node.query('square(3,Y)',{limit:1});
    assert.equal(result.type,'success');assert.equal(result.more,false);assert.equal(result.data[0].Y,'9');
    result=await node.query('member(X,[a,b,c])',{limit:1});
    assert.equal(result.data[0].X,'a');assert.equal(result.more,true);
    result=await node.next();assert.equal(result.data[0].X,'b');
    await node.stop();
    assert.equal((await node.query('true')).type,'success');
    assert.equal((await node.query('self(S),spawn(receive({ping(From)->From!pong}),P),P!ping(S),receive({pong->true})')).type,'success');
    result=await node.query('spawn(receive({stop->true}),P),monitor(P,R),exit(P,kill),receive({down(P,R,_)->true})');assert.equal(result.type,'success',JSON.stringify({result,events:events.slice(-10)}));
    result=await node.query(`statechart_spawn(P,[trace(true),src_text('<statechart version="0.2" initial="s"><state id="s"/></statechart>')]),exit(P,kill)`);
    assert.equal(result.type,'success',JSON.stringify(result));
    assert.ok(events.some(e=>e.type==='statechart_trace'));
    assert.equal((await node.query('writeln(standalone),throw(test_error)')).type,'error');
    assert.ok(events.some(e=>e.type==='output' && e.data.includes('standalone')));
    result=await node.query('read(X)');assert.equal(result.data[0].X,'hello');
    await assert.rejects(node.query('broken('),/syntax_error/);
    await node.open();
    assert.equal((await node.query('true')).type,'success');
    let waiting=node.query('receive({never->true})');
    await wait(40);await node.abort();
    assert.equal((await waiting).type,'abort');
    assert.equal((await node.query('true')).type,'success');
    waiting=node.query('receive({never->true})');
    node.dispose();await assert.rejects(waiting,/disposed/);
    assert.equal(Object.keys(node.swiWasmActorWorkers).length,0);
    assert.throws(()=>node.open(),/disposed/);
  } finally {node.dispose();}
  const withDatabase=create({sharedDatabaseUrl:'http://runtime.invalid/host/shared.pl'});
  try {
    await withDatabase.open();
    assert.equal((await withDatabase.query('custom_fact(host_supplied)')).type,'success');
  } finally {withDatabase.dispose();}
  const broken=create({engineUrl:'http://runtime.invalid/release/missing.js'});
  try {
    await assert.rejects(broken.open(),/unexpected engine URL/);
    assert.equal(Object.keys(broken.swiWasmActorWorkers).length,0);
  } finally {broken.dispose();}
  let manual;
  manual=create({onEvent:event=>{if(event.type==='prompt')manual.input('manual_answer.');}});
  try {
    await manual.open();
    const answer=await manual.query('read(X)');assert.equal(answer.data[0].X,'manual_answer');
  } finally {manual.dispose();}
  const starting=create();const ready=starting.open();starting.dispose();
  await assert.rejects(ready,/disposed/);
  console.log('Standalone browser node: real workers, custom assets/database, queries, paging, actors, monitors, I/O, abort and disposal passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
