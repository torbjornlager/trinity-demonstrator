// In-page abort latency: time from a click event dispatched in the page to WebSocket.send of the abort.
const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch({executablePath:process.env.CHROME_PATH});const out=[];
for (const n of (process.env.NODES||'3,4,5').split(',')) for (let i=0;i<3;i++) {
 const ctx=await b.newContext({viewport:{width:1600,height:1100}});const p=await ctx.newPage();
 await p.addInitScript(()=>{const s=WebSocket.prototype.send;window.__sends=[];WebSocket.prototype.send=function(d){if(/abort/.test(String(d)))window.__sends.push(performance.now());return s.call(this,d);};});
 await p.goto(`https://n${n}.elfenbenstornet.se/demonstrator`);await p.waitForFunction(()=>typeof vm!=='undefined'&&vm.terminal);
 const d=p.getByRole('button',{name:'Dismiss',exact:true});if(await d.isVisible().catch(()=>false))await d.click();
 await p.evaluate(()=>{vm.terminal.clear();vm.terminal.exec('between(1,inf,I), writeln(I), fail.')});await p.waitForTimeout(3000);
 const btn=p.getByRole('button',{name:'Abort',exact:true});const h=await btn.elementHandle();
 const r=await p.evaluate(async el=>{const t=performance.now();el.click();await new Promise(r=>setTimeout(r,1000));const s=window.__sends.find(x=>x>=t);return {clickToSendMs:s===undefined?null:Math.round(s-t)};},h);
 out.push({node:+n,run:i+1,...r});console.log(JSON.stringify(out[out.length-1]));await ctx.close();}
await b.close();require('fs').writeFileSync(process.env.OUT,JSON.stringify(out,null,1));})();
