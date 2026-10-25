/* Runtime identity must come from /version, not the origin serving UI assets. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../web/demonstrator.html'), 'utf8');
function method(name, fetcher) {
  const match = html.match(new RegExp('^          '+name+': function\\(([^)]*)\\) \\{([\\s\\S]*?)^          \\},', 'm'));
  assert.ok(match, name);
  return new Function('fetch','nodeLabelForUrl', 'return function('+match[1]+'){'+match[2]+'}')(fetcher, ()=>'localhost:3060');
}
function component(fetcher) {
  const obj = {portalVersion:'0.2.0',portalSwiplVersion:'',portalTreallaVersion:'',isBrowserSwiWasmMode:false,
    showTerminalGreeting:true,effectiveTransportProfile:'actor',currentPortalNodeUrl:'http://localhost:3060'};
  for (const name of ['portalRuntimeName','portalRuntimeUrl','portalRuntimeVersion']) {
    Object.defineProperty(obj,name,{get(){return method(name).call(this);}});
  }
  obj.terminalGreetingText=method('terminalGreetingText');
  obj.fetchPortalVersion=method('fetchPortalVersion',fetcher);
  return obj;
}
function response(json) {return Promise.resolve({ok:true,json:()=>Promise.resolve(json)});}
(async()=>{
  let obj=component(()=>response({web_prolog:'trealla-port',trealla:'3.14.10',protocol:1}));
  assert.equal(obj.portalRuntimeName,'Prolog'); // Unknown is not SWI.
  await obj.fetchPortalVersion();
  assert.equal(obj.portalRuntimeName,'Trealla Prolog');
  assert.equal(obj.portalRuntimeVersion,'3.14.10');
  assert.equal(obj.portalVersion,'0.2.0'); // Backend identifier is not a package version.
  assert.match(obj.terminalGreetingText(),/trealla-prolog\/trealla-prolog\]Trealla Prolog/);
  assert.ok(!obj.terminalGreetingText().includes('SWI-Prolog'));
  obj.isBrowserSwiWasmMode=true;
  assert.equal(obj.portalRuntimeName,'SWI-Prolog');
  assert.match(obj.terminalGreetingText(),/SWI-WASM/);
  assert.match(obj.terminalGreetingText(),/swi-prolog.org/);
  obj.isBrowserSwiWasmMode=false;
  obj.fetchPortalVersion=method('fetchPortalVersion',()=>response({web_prolog:'0.2.1',swipl:'10.1.18'}));
  await obj.fetchPortalVersion();
  assert.equal(obj.portalRuntimeName,'SWI-Prolog');
  assert.equal(obj.portalTreallaVersion,'');
  assert.equal(obj.portalRuntimeVersion,'10.1.18');
  assert.equal(obj.portalVersion,'0.2.1');
  obj=component(()=>Promise.reject(new Error('offline')));
  await obj.fetchPortalVersion();
  assert.equal(obj.portalRuntimeName,'Prolog');
  assert.ok(!obj.terminalGreetingText().includes('SWI-Prolog'));
  assert.ok(html.includes('initialNodeInfoReady = Promise.all([initialNodeInfoReady, this.fetchNodeInfo()]);'));
  assert.ok(html.includes('initialNodeInfoReady.then(function()'));
  console.log('Portal runtime identity: Trealla, native SWI, WASM and unavailable-version checks passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
