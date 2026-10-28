'use strict';
const assert=require('node:assert/strict');
const create=require('../web/vendor/trinity-host.js');
const location=new URL('https://assets.example/releases/0.1/index.html');
const legacy=create({},new URL('http://localhost:3060/portal'));
assert.equal(legacy.endpoint('/call'),'http://localhost:3060/call');
assert.equal(legacy.websocket(),'ws://localhost:3060/ws');
assert.equal(legacy.runtimeAssets(),null);
assert.equal(legacy.defaultNode,null);
assert.equal(legacy.credentials,'same-origin');
assert.equal(legacy.loginUrl,null);
const local=create({mode:'static',assetBase:'/releases/0.1/'},location);
assert.equal(local.defaultNode,'swi-wasm');
assert.equal(local.nodeBase,null);
assert.throws(()=>local.endpoint('/call'),/no configured remote node/);
assert.equal(local.runtimeAssets().workerUrl,'https://assets.example/releases/0.1/swi_wasm_actor_worker.js');
// Vue must leave this object raw: reactive proxies cannot cross postMessage.
assert.ok(Object.isFrozen(local.runtimeAssets()));
const configured=create({mode:'static',assetBase:'/releases/0.1/',nodeUrl:'https://node.example/prolog',credentials:'include',loginPath:'/login',logoutPath:'/logout'},location);
assert.equal(configured.endpoint('/toplevel_call'),'https://node.example/prolog/toplevel_call');
assert.equal(configured.websocket(),'wss://node.example/prolog/ws');
assert.equal(configured.loginUrl,'https://node.example/prolog/login');
assert.equal(configured.logoutUrl,'https://node.example/prolog/logout');
assert.throws(()=>create({credentials:'unsafe'},location));
for(const path of ['/https://elsewhere.example/','/../outside','/\\\\elsewhere.example/']) assert.throws(()=>configured.endpoint(path));
assert.equal(configured.asset('examples/a.pl'),'https://assets.example/releases/0.1/examples/a.pl');
for(const nodeUrl of ['javascript:alert(1)','https://u:secret@node.example','https://node.example/?token=secret','https://node.example/#fragment','http://node.example'])
 assert.throws(()=>create({nodeUrl},location));
assert.throws(()=>configured.endpoint('//elsewhere.example/call'));
console.log('Host configuration: legacy defaults, static assets, endpoint separation and URL validation passed');
// Exercise actual presenter methods with a distinct service and asset origin.
const fs=require('node:fs');
const html=fs.readFileSync(require('node:path').join(__dirname,'../web/demonstrator.html'),'utf8');
function presenter(name,fetcher) {
 const m=html.match(new RegExp('^          '+name+': function\\(([^)]*)\\) \\{([\\s\\S]*?)^          \\},','m'));
 assert.ok(m,name);
 return new Function('TrinityHost','fetch','return function('+m[1]+'){'+m[2]+'}')(configured,fetcher);
}
(async()=>{
 let called;
 const response=await presenter('requestJson',async(url,options)=>{
  called={url,options};return {ok:true,text:async()=>'{"type":"success","data":[]}'};
 }).call({log(){}},'/call',{method:'POST',params:{goal:'true',format:'json'}});
 assert.equal(called.url,'https://node.example/prolog/call');
 assert.equal(called.options.body,'goal=true&format=json');
 assert.equal(called.options.credentials,'include');
 assert.equal(response.type,'success');
 assert.equal(presenter('wsUrl').call({}),'wss://node.example/prolog/ws');
 const state={portalSwiplVersion:'',portalTreallaVersion:''};
 await presenter('fetchPortalVersion',async(url)=>{
  assert.equal(url,'https://node.example/prolog/version');return {ok:true,json:async()=>({swipl:'test-engine'})};
 }).call(state);
 assert.equal(state.portalSwiplVersion,'test-engine');
 let disconnected=0;
 await assert.rejects(()=>presenter('requestJson',async()=>({status:401,ok:false,text:async()=>'{"message":"Authentication required"}'})).call({log(){},disconnectRemoteNode(){disconnected++;}},'/call'),/Authentication required/);
 assert.equal(disconnected,1);
 console.log('Presenter integration: HTTP body, runtime metadata and WebSocket target use the configured service');
})().catch(e=>{console.error(e);process.exitCode=1;});
