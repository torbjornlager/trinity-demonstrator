// Abort the actual bulk DCG tutorial query while it is producing output.
'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),{chromium}=require('playwright');
// Candidate parent HTML uses the real public backend; nothing is deployed.
// GENERATION_PUBLISHED=1 instead exercises the existing published interface.
// Bound 8 is the unchanged exercise; bound 14 keeps generation running for Abort.
const rows=[];
(async()=>{
 assert.ok(process.env.ACTOR_URL,'set ACTOR_URL to a test ACTOR node');
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH,headless:true});
 try{
  for(const mode of (process.env.GENERATION_MODES||'native,worker,main').split(','))for(const upperBound of (process.env.GENERATION_BOUNDS||'8,14').split(',').map(Number)){
   const ctx=await browser.newContext({viewport:{width:1600,height:1100}}),p=await ctx.newPage();
   if(!process.env.GENERATION_PUBLISHED)await p.route('**/demonstrator*',async route=>{
    if(new URL(route.request().url()).pathname==='/demonstrator')await route.fulfill({contentType:'text/html',body:fs.readFileSync(require('node:path').join(__dirname,'../../web/demonstrator.html'),'utf8')});
    else await route.continue();
   });
   const errors=[];p.on('pageerror',e=>errors.push(String(e)));
   p.setDefaultTimeout(12000);const row={mode,upperBound,url:process.env.ACTOR_URL};rows.push(row);
   if(mode!=='native')await ctx.addInitScript(mode=>localStorage.setItem('wb.swiWasmModel',mode),mode);
   try{
    await p.goto(process.env.ACTOR_URL+'/demonstrator'+(mode==='native'?'':'?node=swi-wasm'));
    await p.getByRole('button',{name:'Dismiss',exact:true}).click();
    if(mode==='worker')await p.waitForFunction(()=>vm.swiWasm2ShellReady);
    if(mode==='main')await p.waitForFunction(()=>vm.swiWasmProlog);
    await p.evaluate(()=>vm.openTutorialDocument('/actor-profile-tutorial'));await p.waitForTimeout(300);
    const f=p.frames().find(f=>new URL(f.url()).pathname==='/actor-profile-tutorial');
    await f.locator('[onclick=\'consult("#dcg1")\']').click();
    await p.waitForFunction(()=>!vm.terminalBusy&&!vm.terminal.paused());
    if(mode==='native')await p.waitForFunction(()=>vm.wsPid&&!vm.wsSpawnPromise&&vm.wsLoadedText.includes('s(s('));
    if(mode==='worker')await p.waitForFunction(()=>vm.swiWasm2ShellReady&&vm.swiWasm2LoadedSource.includes('s(s('));
    await f.evaluate(upperBound=>{
     if(upperBound!==8)document.querySelector('#dcg3').textContent=document.querySelector('#dcg3').textContent.replace('between(1,8,N)','between(1,'+upperBound+',N)');
     document.querySelector('[onclick=\'pasteAndAskExample("#dcg3")\']').addEventListener('click',()=>{
     const {vm}=parent;
     parent.generationAbortProbe={start:parent.performance.now(),outputStart:vm.terminal.get_output().length};
     parent.setTimeout(()=>{
      const probe=parent.generationAbortProbe;probe.clickAt=parent.performance.now();probe.busyAtClick=vm.terminalBusy;
      const button=parent.document.querySelector('.terminal-action.abort');probe.disabled=button.disabled;
      button.click();probe.clickReturnedAt=parent.performance.now();
     },100);
     },{once:true});
    },upperBound);
    await f.locator('[onclick=\'pasteAndAskExample("#dcg3")\']').click();
    await p.waitForFunction(()=>{
     const probe=window.generationAbortProbe;
     return probe.clickAt&&!vm.terminalBusy&&vm.queryState==='query'&&
       (!probe.busyAtClick||/abort/i.test(vm.terminal.get_output().slice(probe.outputStart)));
    },{},{timeout:15000});
    row.observation=await p.evaluate(()=>({...window.generationAbortProbe,finished:performance.now(),output:vm.terminal.get_output().slice(window.generationAbortProbe.outputStart),logs:vm.logEntries.slice(0,8)}));
    assert.ok(row.observation.clickAt-row.observation.start<1500,'Streamed output must not starve the Abort click');
    if(upperBound===14)assert.ok(row.observation.busyAtClick,'Abort must run before natural completion');
    if(row.observation.busyAtClick){
     assert.equal(row.observation.disabled,false,'Abort stays enabled during output');
     assert.match(row.observation.output,/abort/i,'Abort must be acknowledged');
    }
    assert.ok(row.observation.finished-row.observation.clickAt<5000,'Abort returns promptly');
    await p.evaluate(()=>{vm.terminal.exec('phrase(s(Tree),[john,saw,a,man]),Fresh=usable.');return true;});
    await p.waitForFunction(()=>!vm.terminalBusy&&vm.lastBindings.Fresh==='usable');
    assert.deepEqual(errors,[],'no browser exceptions');
    row.status='pass';console.log(mode,upperBound,'pass');
   }catch(e){row.status='fail';row.error=String(e.stack||e);row.snapshot=await p.evaluate(()=>({busy:vm.terminalBusy,state:vm.queryState,probe:window.generationAbortProbe,output:vm.terminal.get_output().slice(-1500)})).catch(()=>null);console.error(mode,upperBound,String(e));}
   finally{await ctx.close();if(process.env.GENERATION_REPORT)fs.writeFileSync(process.env.GENERATION_REPORT,JSON.stringify(rows,null,2)+'\n');}
  }
 }finally{await browser.close();}
 if(rows.some(r=>r.status!=='pass'))process.exitCode=1;
})().catch(e=>{console.error(e);process.exitCode=1;});
