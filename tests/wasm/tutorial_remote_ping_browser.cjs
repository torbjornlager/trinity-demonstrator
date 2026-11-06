// Exercise the actual published tutorial controls, source transfer and terminal.
// ACTOR_URL selects the UI host. REMOTE_WS_URL optionally routes its N4 peer
// to a disposable candidate; CANDIDATE_TUTORIALS=1 serves local tutorial HTML.
'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
const rows=[];
(async()=>{
 const origin=process.env.ACTOR_URL||'https://n3.elfenbenstornet.se';
 const remote=process.env.REMOTE_WS_URL||'';
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH,headless:true,
  args:remote?['--disable-features=LocalNetworkAccessChecks']:[]});
 try{
  for(const mode of ['worker','main'])for(const doc of ['actor-profile-tutorial','swi-wasm-tutorial','tutorial']){
   const context=await browser.newContext({viewport:{width:1600,height:1100}});
   await context.addInitScript(({mode,remote})=>{
    localStorage.setItem('wb.swiWasmModel',mode);
    if(remote){const Native=window.WebSocket;window.WebSocket=class extends Native{
     constructor(url,protocols){super(String(url).startsWith('wss://n4.elfenbenstornet.se/')?remote:url,protocols);}
    };}
   },{mode,remote});
   const page=await context.newPage();page.setDefaultTimeout(15000);
   const row={mode,doc,status:'running',peer:remote||'published N4'};rows.push(row);
   if(process.env.CANDIDATE_TUTORIALS)await page.route('**/'+doc,r=>r.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../../web',doc+'.html'),'utf8')}));
   try{
    await page.goto(origin+'/demonstrator?node=swi-wasm');
    await page.getByRole('button',{name:'Dismiss',exact:true}).click();
    await page.waitForFunction(()=>vm.isSwiWasm2Mode?vm.swiWasm2ShellReady:!!vm.swiWasmProlog);
    await page.evaluate(doc=>vm.openTutorialDocument('/'+doc),doc);
    const frame=page.frameLocator('iframe[src="/'+doc+'"]');
    await frame.locator('[onclick=\'consult("#cpw-remote-pingpong-source")\']').click();
    if(mode==='worker')await page.waitForFunction(()=>vm.swiWasm2ShellReady&&vm.swiWasm2LoadedSource.includes('ping_pong_remote'));
    await page.waitForFunction(()=>!vm.terminalBusy);
    await frame.locator('[onclick=\'pasteAndAskExample("#cpw-remote-pingpong-run")\']').click();
    await page.waitForFunction(()=>!vm.terminalBusy&&vm.terminal.get_output().includes('Pong finished.'));
    const output=await page.evaluate(()=>vm.terminal.get_output());
    assert.equal((output.match(/Ping received pong\./g)||[]).length,3,output);
    assert.equal((output.match(/Pong received ping\./g)||[]).length,3,output);
    assert.match(output,/Ping finished\./);assert.match(output,/true\./);
    assert.doesNotMatch(output,/<js>|terminal-error|Not authorized/);
    await page.evaluate(()=>{vm.terminal.exec('AfterPing=ready.');return true;});
    await page.waitForFunction(()=>!vm.terminalBusy&&vm.lastBindings.AfterPing==='ready');
    Object.assign(row,{status:'pass',ping_replies:3,remote_output:3,completed:true,fresh_query:true});
    console.log(mode,doc,'pass');
   }catch(error){row.status='fail';row.error=String(error.stack||error);row.snapshot=await page.evaluate(()=>({busy:vm.terminalBusy,state:vm.queryState,output:vm.terminal.get_output().slice(-2000),logs:vm.logEntries.slice(0,8)})).catch(()=>null);console.error(mode,doc,String(error));}
   finally{await context.close();if(process.env.PING_REPORT)fs.writeFileSync(process.env.PING_REPORT,JSON.stringify(rows,null,2)+'\n');}
  }
 }finally{await browser.close();}
 if(rows.some(r=>r.status!=='pass'))process.exitCode=1;
})().catch(e=>{console.error(e);process.exitCode=1;});
