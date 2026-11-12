'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../../web/demonstrator.html'),'utf8');
const marker='handleSwiWasm2ToplevelMessage: function(pid, message) {';
const start=source.indexOf(marker)+marker.length;
assert.ok(start>=marker.length);
const end=source.indexOf('\n          },',start);
const handle=Function('pid','message',source.slice(start,end));
(async()=>{
 const posted=[],resolve=[],prompts=[];
 const host={terminal:{},swiWasm2ShellPid:37,
   swiWasmActorWorkers:{37:{worker:{postMessage:m=>posted.push(m)},done:false}},
   logSwiWasmWorkerTraffic:()=>{},
   requestSwiWasmActorInput:p=>{prompts.push(p);return new Promise(r=>resolve.push(r));}};
 assert.equal(handle.call(host,37,{type:'prompt',data:'same prompt',prompt_ref:'1001'}),true);
 assert.equal(handle.call(host,37,{type:'prompt',data:'same prompt',prompt_ref:'1002'}),true);
 resolve[1]('second.');await Promise.resolve();
 resolve[0]('first.');await Promise.resolve();
 assert.deepEqual(prompts,['same prompt','same prompt']);
 assert.deepEqual(posted,[
   {command:'toplevel_respond',pid:37,input:'second.',prompt_ref:'1002'},
   {command:'toplevel_respond',pid:37,input:'first.',prompt_ref:'1001'}]);
 console.log('Shared UI preserves each prompt reference even when input promises complete out of order');
})().catch(e=>{console.error(e);process.exitCode=1;});
