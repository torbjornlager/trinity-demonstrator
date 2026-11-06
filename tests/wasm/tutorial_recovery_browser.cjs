// Candidate tutorial HTML, real parent UI and real actor backends/workers.
// TUTORIAL_RECOVERY_PUBLISHED=1 verifies the published pages without substitution.
// ACTOR_URL selects an ACTOR node; RECOVERY_MODES defaults to native,worker.
// Requires Playwright and Chrome (CHROME_PATH), as the other browser checks do.
'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'../..'),results=[];
const documents=['actor-profile-tutorial','tutorial','swi-wasm-tutorial'];
const compact=x=>String(x).replace(/\s+/g,'');
(async()=>{
 assert.ok(process.env.ACTOR_URL,'set ACTOR_URL to a test ACTOR node');
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH,headless:true});
 try{
  for(const mode of (process.env.RECOVERY_MODES||'native,worker').split(',')){
   for(const doc of documents){
    const ctx=await browser.newContext({viewport:{width:1600,height:1100}}),p=await ctx.newPage();
    p.setDefaultTimeout(20000);const errors=[];p.on('pageerror',e=>errors.push(String(e)));
    if(mode!=='native')await ctx.addInitScript(mode=>localStorage.setItem('wb.swiWasmModel',mode),mode);
    if(process.env.TUTORIAL_RECOVERY_PUBLISHED!=='1')await p.route(url=>documents.some(doc=>new URL(url).pathname==='/'+doc),route=>{
     const name=new URL(route.request().url()).pathname.slice(1);
     return route.fulfill({status:200,contentType:'text/html; charset=utf-8',body:fs.readFileSync(path.join(root,'web',name+'.html'),'utf8')});
    });
    try{
     await p.goto(process.env.ACTOR_URL+'/demonstrator'+(mode==='native'?'':'?node=swi-wasm'));
     await p.getByRole('button',{name:'Dismiss',exact:true}).click();
     if(mode==='worker')await p.waitForFunction(()=>vm.swiWasm2ShellReady);
     if(mode==='main')await p.waitForFunction(()=>vm.swiWasmProlog);
     await p.evaluate(doc=>vm.openTutorialDocument('/'+doc),doc);await p.waitForTimeout(300);
     const frame=p.frames().find(f=>new URL(f.url()).pathname==='/'+doc);
     async function call(id,wait=true){
      const start=await p.evaluate(()=>vm.terminal.get_output().length);
      await frame.locator(`[onclick='pasteAndAskExample("#${id}")']`).click();
      await p.waitForTimeout(100);
      if(wait)await p.waitForFunction(()=>!vm.terminalBusy,{},{timeout:20000});
      return p.evaluate(start=>({bindings:vm.lastBindings,output:vm.terminal.get_output().slice(start)}),start);
     }
     const timeout=await call('recovery-timeout-retry');
     assert.equal(compact(timeout.bindings.Final),'success([ready],false)',JSON.stringify(timeout));
     assert.ok(timeout.bindings.First==='timeout'||compact(timeout.bindings.First)===compact(timeout.bindings.Final));
     const record={mode,doc,first:timeout.bindings.First,final:timeout.bindings.Final};
     await frame.locator('[onclick=\'consult("#recovery-server-source")\']').click();
     await p.waitForFunction(()=>!vm.terminalBusy&&!vm.terminal.paused());
     if(mode==='native')await p.waitForFunction(()=>vm.wsPid&&!vm.wsSpawnPromise&&vm.wsLoadedText.includes('recovery_replacement'));
     if(mode==='worker')await p.waitForFunction(()=>vm.swiWasm2ShellReady&&vm.swiWasm2LoadedSource.includes('recovery_replacement'));
     const started=await call('recovery-server-start');
     assert.equal(started.bindings.Stored,'ok',JSON.stringify(started));
     const before=started.bindings.Before,sup=started.bindings.Sup;assert.ok(before&&sup);
     const failure=await call('recovery-server-malformed');
     assert.equal(compact(failure.bindings.Failure),'server_down(false)',JSON.stringify(failure));
     const replacement=await call('recovery-server-check');
     assert.notEqual(replacement.bindings.After,before);
     assert.ok(replacement.bindings.After&&replacement.bindings.After!=='undefined');
     assert.equal(replacement.bindings.Items,'[]',JSON.stringify(replacement));
     assert.ok(compact(replacement.bindings.Counts).includes('active-1'),JSON.stringify(replacement));
     const stopped=await call('recovery-server-stop');assert.ok(!/terminal-error/.test(stopped.output),stopped.output);
     // A cleanup check in the terminal also verifies that the stored alias went away.
     await p.evaluate(()=>vm.terminal.exec('whereis(recovery_store,AliasAfterStop).'));
     await p.waitForFunction(()=>!vm.terminalBusy&&vm.lastBindings.AliasAfterStop==='undefined');
     await call('recovery-abort-wait',false);await p.waitForFunction(()=>vm.terminalBusy);
     const abortStart=await p.evaluate(()=>vm.terminal.get_output().length);
     await frame.locator('[onclick="abortRecoveryQuery()"]').click();
     await p.waitForFunction(()=>!vm.terminalBusy&&vm.queryState==='query');
     const abortOutput=await p.evaluate(start=>vm.terminal.get_output().slice(start),abortStart);
     assert.match(abortOutput,/abort/i,'explicit Abort is acknowledged before the fresh query');
     const fresh=await call('recovery-abort-fresh');assert.equal(fresh.bindings.AfterAbort,'ready',JSON.stringify(fresh));
     assert.deepEqual(errors,[]);
     Object.assign(record,{before,after:replacement.bindings.After,supervisor:sup,items:replacement.bindings.Items,cleanup:true,abort_and_fresh_query:true,status:'pass'});
     results.push(record);console.log(mode,doc,'pass');
    }catch(e){results.push({mode,doc,status:'fail',detail:String(e.stack||e),snapshot:await p.evaluate(()=>({state:vm.queryState,busy:vm.terminalBusy,bindings:vm.lastBindings,output:vm.terminal.get_output().slice(-6000),logs:vm.logEntries.slice(0,5)})).catch(()=>null)});throw e;}
    finally{await ctx.close();}
   }
  }
 }finally{
  await browser.close();
  if(process.env.TUTORIAL_RECOVERY_REPORT)fs.writeFileSync(process.env.TUTORIAL_RECOVERY_REPORT,JSON.stringify(results,null,2)+'\n');
 }
 assert.ok(results.some(r=>r.first==='timeout'),'at least one run exercises the timeout and retry path');
 console.log(JSON.stringify(results,null,2));
})().catch(e=>{console.error(e);process.exitCode=1;});
