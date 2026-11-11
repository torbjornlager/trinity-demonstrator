'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const createHost = require('../web/vendor/trinity-host.js');
const helpers = require('../web/vendor/swi-wasm-node.js').helpers;
const html = fs.readFileSync(require('node:path').join(__dirname, '../web/demonstrator.html'), 'utf8');
const location = new URL('http://localhost:3057/demonstrator');
const remoteNodes = [1,2,3,4,5].map(n => ({url:`https://n${n}.elfenbenstornet.se`,runtime:n<5?'swi':'trealla'}));
remoteNodes.push({url:'http://localhost:3057',runtime:'gprolog'});
remoteNodes.push({url:'https://n7.elfenbenstornet.se',runtime:'eclipse'});
const context = vm.createContext({URL, window:{location},
  normalizeNodeUrl:helpers.normalizeNodeUrl, isLoopbackHost:helpers.isLoopbackHost,
  browserRuntimeRouteState:()=>({main:false,worker:false}),
  TrinityHost:createHost({remoteNodes},location)});
for (const name of ['portalHrefForNodeUrl','loopbackNodeLabel','nodeLabelForUrl',
                    'derivePortalNodeUrls','profileTutorialForCurrentRuntime']) {
  const match = html.match(new RegExp('^      function '+name+'\\([^]*?^      \\}', 'm'));
  assert.ok(match, name);
  vm.runInContext(match[0],context);
}
function computed(name,state) {
  const match = html.match(new RegExp('^          '+name+': function\\(([^)]*)\\) \\{([^]*?)^          \\},','m'));
  assert.ok(match,name);
  return vm.runInContext('(function('+match[1]+'){'+match[2]+'})',context).call(state);
}
const state = {portalNodes:context.derivePortalNodeUrls(location.origin),
  currentPortalNodeUrl:location.origin,isBrowserSwiWasmMode:false};
assert.equal(state.portalNodes.map(n=>n.label).join(','),'N1,N2,N3,N4,N5,N6,N7');
assert.equal(context.profileTutorialForCurrentRuntime().profile,'isobase');
state.headerRemoteNodeButtons = computed('headerRemoteNodeButtons',state);
state.headerRemoteNonSwiNodeButtons = computed('headerRemoteNonSwiNodeButtons',state);
assert.equal(computed('headerRemoteSwiNodeButtons',state).map(n=>n.label).join(','),'N1,N2,N3,N4');
assert.equal(state.headerRemoteNonSwiNodeButtons.map(n=>n.label).join(','),'N5,N6,N7');
assert.equal(state.headerRemoteNonSwiNodeButtons.find(n=>n.active).label,'N6');
assert.equal(computed('headerNonSwiNodeSelected',state),true);
assert.equal(computed('currentPortalNodeAddress',state),'http://localhost:3057');
context.TrinityHost = createHost({},new URL('https://n5.elfenbenstornet.se/demonstrator'));
assert.equal(context.derivePortalNodeUrls('https://n5.elfenbenstornet.se').map(n=>n.label).join(','),'N1,N2,N3,N4,N5,N6,N7');
console.log('Node catalog: local N6 placement, active state, shared DB, ISOBASE tutorial and public HTTPS N6 catalog passed');

const n7=state.headerRemoteNonSwiNodeButtons.find(n=>n.label==='N7');assert.equal(n7.runtime,'eclipse');assert.equal(n7.ownerOnly,true);assert.equal(n7.href,'https://n7.elfenbenstornet.se/');
