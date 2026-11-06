// Run with Playwright and two disposable nodes serving this checkout's assets:
// ISOBASE_URL=http://localhost:PORT ACTOR_URL=http://localhost:PORT node this-file
'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),{chromium}=require('playwright');
const cases=[['laptop','permitted'],['restricted','forbidden'],['vpn','conflicting'],
             ['missing','insufficient(missing_fields)'],['training','insufficient(policy_gap)'],
             ['budget','insufficient(policy_gap)']];
const results=[];
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.CHROME_PATH,headless:true});
 try{
  for(const [profile,url] of [['isobase',process.env.ISOBASE_URL],['actor',process.env.ACTOR_URL]]){
   assert.ok(url,'set both disposable node URLs');
   for(const doc of ['/tutorial','/actor-profile-tutorial']){
    const p=await browser.newPage({viewport:{width:1600,height:1100}}),requests=[];
    p.on('request',r=>{if(/\/(call|toplevel_spawn)(?:\?|$)/.test(r.url()))requests.push(r.url());});
    try{
     await p.goto(url+'/demonstrator');await p.getByRole('button',{name:'Dismiss',exact:true}).click();
     await p.evaluate(doc=>vm.openTutorialDocument(doc),doc);
     await p.waitForTimeout(300);const frame=p.frames().find(f=>new URL(f.url()).pathname===doc);
     const load=frame.locator('[onclick=\'loadPortableSource("#service-policy-source")\']');
     // Public nodes may deliberately hide entire chapters via tutorial_sections.
     // Never force a click on a control that their readers cannot see.
     if(!await load.isVisible()){
      results.push({profile,doc,status:'not_exposed',reason:'chapter hidden by node tutorial_sections'});
      continue;
     }
     await load.click();
     if(profile==='isobase')await p.waitForFunction(()=>vm.tutorialRequestSource.includes('classify(Fields'));
     else await p.waitForFunction(()=>vm.wsPid&&!vm.wsSpawnPromise);
     for(const [name,decision] of cases){
      await frame.locator(`[onclick='pasteAndAskExample("#service-policy-${name}")']`).click();
      await p.waitForFunction(decision=>!vm.terminalBusy&&vm.lastBindings.Decision===decision,decision);
     }
     if(profile==='isobase'){
      const calls=requests.filter(u=>new URL(u).pathname==='/call');
      assert.equal(calls.length,6);
      assert.ok(calls.every(u=>new URL(u).searchParams.get('src_text').includes('classify(Fields')));
      assert.ok(!requests.some(u=>new URL(u).pathname==='/toplevel_spawn'));
     }
     results.push({profile,doc,decisions:cases.map(c=>c[1]),status:'pass'});
    }finally{await p.close();}
   }
  }
  const p=await browser.newPage({viewport:{width:1600,height:1100}});
  try{
   await p.goto(process.env.ACTOR_URL+'/demonstrator');await p.getByRole('button',{name:'Dismiss',exact:true}).click();
   await p.evaluate(()=>vm.openTutorialDocument('/actor-profile-tutorial'));await p.waitForTimeout(300);
   const frame=p.frames().find(f=>new URL(f.url()).pathname==='/actor-profile-tutorial');
   await frame.locator('[onclick=\'consult("#srv-fridge-source")\']').click();await p.waitForFunction(()=>vm.wsPid&&!vm.wsSpawnPromise);
   async function ask(q){const before=await p.evaluate(()=>vm.terminal.get_output().length);await p.evaluate(q=>vm.terminal.exec(q),q);await p.waitForTimeout(100);await p.waitForFunction(()=>!vm.terminalBusy);return p.evaluate(before=>({output:vm.terminal.get_output().slice(before),bindings:vm.lastBindings}),before);}
   await frame.locator('[onclick=\'pasteAndAskExample("#srv-spawn")\']').click();await p.waitForFunction(()=>!vm.terminalBusy&&vm.lastBindings.Sup);
   const sup=await p.evaluate(()=>vm.lastBindings.Sup);
   const failure=await ask('server_request(fridge,sore(milk),Response).');
   assert.ok(failure.output.includes('Server terminated before replying: false'),failure.output);
   assert.ok(!failure.output.includes('Unknown message'),failure.output);
   assert.equal((await ask('server_request(fridge,store(eggs),Response).')).bindings.Response,'ok');
   await ask('exit('+sup+',kill).');results.push({title:'fridge failure display and supervised recovery',status:'pass'});
  }finally{await p.close();}
 }finally{await browser.close();}
 if(process.env.TUTORIAL_REPORT)fs.writeFileSync(process.env.TUTORIAL_REPORT,JSON.stringify(results,null,2)+'\n');
 console.log(JSON.stringify(results,null,2));
})().catch(e=>{console.error(e);process.exitCode=1;});
