// Consumer integration and conformance-adapter compatibility entry point.
'use strict';
const path=require('node:path'),fs=require('node:fs'),cp=require('node:child_process');
const root=path.resolve(__dirname,'../..');
const result=cp.spawnSync('python3',[path.join(root,'tools/setup_swi.py'),'--validate'],{encoding:'utf8'});
if(result.status!==0)throw new Error(result.stderr||'Run pinned dependency setup first');
const setup=JSON.parse(result.stdout);
const script=path.join(setup.browser_package,'tests/wasm/swi_wasm_contracts.js');
process.env.SWI_WASM_TEST_HOST=path.join(__dirname,'swi_wasm_host_cases.cjs');
process.env.WP_WASM_SOURCE_DIR=setup.wasm_root;
process.env.TRINITY_PINNED_SWI_ROOT=setup.native_root;
if(require.main===module){
 const child=cp.spawnSync(process.execPath,[script,...process.argv.slice(2)],{env:process.env,stdio:'inherit'});
 if(child.error)throw child.error;
 process.exit(child.status===null?1:child.status);
}else module.exports=require(script);
