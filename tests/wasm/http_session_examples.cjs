'use strict';
// Run with Playwright and CHROME_PATH. Every request is intercepted; no live writes.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../..');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH});
 try {
  for(const name of ['http_example-1.html','http-example-2.html']) {
   for(const scenario of ['relation','isobase','404','405','401','403','metadata403','success']) {
    const page=await browser.newPage();let posted=0,refSeen=false,called=0;
    await page.route('https://fixture.invalid/**',async route=>{
     const request=route.request(),p=new URL(request.url()).pathname;
     const reply=(status,body)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(body)});
     if(p==='/example')return route.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(root,'examples/APIs',name),'utf8')});
     if(p==='/node_info')return reply(scenario==='metadata403'?403:200,{profile:['relation','isobase'].includes(scenario)?scenario:'actor'});
     if(request.method()==='POST')posted++;
     if(p==='/toplevel_spawn')return scenario==='success'?reply(200,{pid:42}):reply(Number(scenario),{error:'fixture'});
     if(p==='/toplevel_call') {
      called++;
      if(name==='http_example-1.html')return reply(200,{type:'success',data:[{X:'a'}],more:true});
      return reply(200,{type:'prompt',data:'Input',prompt_ref:'ref42'});
     }
     if(p==='/toplevel_next')return reply(200,{type:'success',data:[{X:'b'},{X:'c'}],more:false});
     if(p==='/toplevel_respond') {
      refSeen=new URLSearchParams(request.postData()).get('prompt_ref')==='ref42';
      return reply(200,{type:'success',data:[{}],more:false});
     }
     return reply(200,{type:'halted'});
    });
    page.on('dialog',d=>d.accept('stop.'));
    await page.goto('https://fixture.invalid/example');
    await page.waitForFunction(()=>!document.getElementById('run-button').disabled);
    const result=await page.locator('#results').innerText(),log=await page.locator('#log').innerText();
    if(['relation','isobase'].includes(scenario)){assert.equal(posted,0);assert.match(result,/does not provide sessions/);}
    else if(['404','405'].includes(scenario)){assert.equal(posted,1);assert.match(result,/HTTP sessions are unavailable/);}
    else if(scenario==='success'){assert.equal(called,1);if(name==='http_example-1.html')assert.equal(result,'a\nb\nc');else {assert.equal(refSeen,true);assert.match(result,/success/);}}
    else {assert.match(log,/error:/);assert.doesNotMatch(result,/unavailable/);if(scenario==='metadata403')assert.equal(posted,0);}
    console.log(name,scenario,'PASS');await page.close();
   }
  }
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
