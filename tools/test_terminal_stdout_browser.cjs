'use strict';
// Real Chrome regression. Optional loopback backends exercise the staged
// renderer and actual wire protocol without changing production assets.
const fs=require('fs'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
const NativeWebSocket=require('ws');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 const rows=[];
 try{
  for(const node of (process.env.STDOUT_NODES||'n3,n5').split(',')){
   const origin=`https://${node}.elfenbenstornet.se`,context=await browser.newContext({viewport:{width:1600,height:1100}});
   const page=await context.newPage();page.setDefaultTimeout(30000);
   const backend=process.env['STDOUT_BACKEND_'+node.toUpperCase()];
   if(backend){
    await context.route(origin+'/**',async route=>{
     const url=new URL(route.request().url());
     if(url.pathname==='/demonstrator')return route.fulfill({path:process.env.STDOUT_HTML,contentType:'text/html'});
     if(['/node_info','/healthz'].includes(url.pathname)||url.pathname.startsWith('/toplevel_')||url.pathname==='/call'){
      const response=await route.fetch({url:backend+url.pathname+url.search});return route.fulfill({response});
     }
     return route.continue();
    });
    await context.routeWebSocket(origin.replace('https:','wss:')+'/ws',route=>{
     const upstream=new NativeWebSocket(backend.replace('http:','ws:')+'/ws',{origin});const queued=[];
     route.onMessage(message=>upstream.readyState===NativeWebSocket.OPEN?upstream.send(message):queued.push(message));
     upstream.on('open',()=>{for(const message of queued)upstream.send(message);});
     upstream.on('message',(message,binary)=>route.send(binary?message:message.toString()));
     upstream.on('error',()=>route.close());upstream.on('close',()=>route.close());route.onClose(()=>upstream.close());
    });
   }
   try{
    await page.goto(origin+'/demonstrator');await page.waitForFunction(()=>typeof vm!=='undefined'&&vm.terminal);
    const dismiss=page.getByRole('button',{name:'Dismiss',exact:true});if(await dismiss.count())await dismiss.click();
    await page.locator('.project-link').filter({hasText:'04 count_server.pl'}).click();
    await page.waitForFunction(()=>vm.wsPid&&!vm.wsSpawnPromise&&!vm.terminalBusy);
    for(const [goal,expected] of [
     ['write(a),write(b).','ab'],
     ['write(a),sleep(0.2),write(b).','ab'],
     ['writeln(a),writeln(b).','a\nb'],
     ['write(a),nl,nl,writeln(b),write(c).','a\n\nb\nc'],
     ["format('a~nb~n~n'),write(c).",'a\nb\n\nc'],
     ['write(after_previous_query).','after_previous_query']]){
      await page.evaluate(goal=>{vm.terminal.clear();vm.terminal.exec(goal);},goal);
      await page.waitForTimeout(350);await page.waitForFunction(()=>!vm.terminalBusy);
      const output=await page.evaluate(()=>vm.terminal.get_output());
      assert.ok(output.includes('\n'+expected+'\ntrue.'),JSON.stringify({node,goal,output,expected}));
      rows.push({node,goal,expected,passed:true});console.log(node,goal,'passed');
    }
   }finally{await context.close();}
  }
 }finally{await browser.close();if(process.env.STDOUT_REPORT)fs.writeFileSync(process.env.STDOUT_REPORT,JSON.stringify(rows,null,2)+'\n');}
})().catch(error=>{console.error(error);process.exitCode=1;});
