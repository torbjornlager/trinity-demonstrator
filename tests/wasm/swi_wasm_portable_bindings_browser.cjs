'use strict';
// Exercise the demonstrator's own terminal interpreter, not the standalone API.
const assert=require('node:assert/strict');
const {chromium}=require('playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 const results=[];
 try {
  for(const mode of ['worker','main']) {
   const page=await browser.newPage();
   await page.addInitScript(mode=>{localStorage.setItem('wb.swiWasmModel',mode);localStorage.setItem('wp.portalIntroDismissed','1');},mode);
   await page.goto(new URL('demonstrator?node=swi-wasm',process.env.RUNTIME_URL||'http://127.0.0.1:8096/').href);
   const dismiss=page.getByRole('button',{name:'Dismiss',exact:true});if(await dismiss.count())await dismiss.click();
   console.log(mode+': demonstrator loaded');
   const log=page.getByRole('log');
   await page.waitForFunction(()=>typeof vm!=='undefined'&&vm.terminal&&!vm.terminalBusy&&(!vm.isSwiWasm2Mode||vm.swiWasm2ShellReady),null,{timeout:30000});
   async function run(goal,more=false,pattern='(?:portable_term|Representation error: portable term)') {
    const before=await log.innerText();
    await page.evaluate(goal=>{vm.terminal.exec(goal);},goal);
    await page.waitForFunction(({more,before,pattern})=>typeof vm!=='undefined'&&!vm.terminalBusy&&(more?vm.queryState==='more':vm.queryState==='query')&&new RegExp(pattern).test(document.querySelector('[role=log]').innerText.slice(before.length).replace(/\u00a0/g,' ')),{more,before,pattern});
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    return (await log.innerText()).slice(before.length).replace(/\u00a0/g,' ');
   }
   const positive=async()=>{
    const text=await run('A=[a],B=[],C=pair(X,X,Y),X\\==Y.',false,'\\nC\\s*=\\s*pair\\(');
    assert.match(text,/\nA\s*=\s*\[a\]/);assert.match(text,/B\s*=\s*\[\]/);
    const pair=/C\s*=\s*pair\(([^,\s]+),\s*\1,\s*([^()\s]+)\)/.exec(text);assert.ok(pair,text);assert.notEqual(pair[1],pair[2]);
   };
   for(const goal of ["A='.'(a,[]).","A='[]'.","A=f().","A=nested([ok,'.'(a,[])]).","throw(error(test('.'(a,[])),_))."]) {
    const text=await run(goal);assert.match(text,/(?:portable_term|Representation error: portable term)/);await positive();
    results.push({mode,check:goal,status:'pass'});
   }
   assert.match(await run("_='.'(a,[]),T=ok.",false,"\\nT\\s*=\\s*ok"),/\nT\s*=\s*ok/);
   results.push({mode,check:'anonymous local value remains local',status:'pass'});
   console.log(mode+': actual demonstrator binding checks pass');await page.close();
  }
  if(process.env.BROWSER_REPORT)require('node:fs').writeFileSync(process.env.BROWSER_REPORT,JSON.stringify({result:'pass',checks:results},null,2)+'\n');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
