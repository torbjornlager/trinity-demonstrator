/* Real native-node/proxy integration. Browser enforcement is separately checked
   through tests/fixtures/cdn_browser_checks.html and the saved UI evidence. */
'use strict';
const assert=require('node:assert/strict'),http=require('node:http'),net=require('node:net'),path=require('node:path'),cp=require('node:child_process'),crypto=require('node:crypto');
const {createGateway}=require('../tests/fixtures/cdn_auth_gateway.cjs');
const root=path.resolve(__dirname,'..'),swipl=process.env.STARTUP_TEST_SWIPL||process.env.SWIPL;
if(!swipl)throw Error('Set STARTUP_TEST_SWIPL or SWIPL to the verified native executable');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function freePort(){const server=net.createServer();await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;await new Promise(r=>server.close(r));return port;}
function request(base,path,method='GET',headers={},body=''){
 return new Promise((resolve,reject)=>{const url=new URL(path,base);const req=http.request(url,{method,headers},res=>{let text='';res.setEncoding('utf8');res.on('data',s=>text+=s);res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,text,json(){return JSON.parse(text);}}));});req.on('error',reject);req.end(body);});
}
function upgrade(base,origin,cookie){
 return new Promise((resolve,reject)=>{const url=new URL('/ws',base);const req=http.request(url,{headers:{Origin:origin,Connection:'Upgrade',Upgrade:'websocket','Sec-WebSocket-Version':'13','Sec-WebSocket-Key':crypto.randomBytes(16).toString('base64'),...(cookie?{Cookie:cookie}:{})}});
 req.on('upgrade',(r,socket)=>resolve({status:101,socket}));req.on('response',r=>{r.resume();resolve({status:r.statusCode});});req.on('error',reject);req.end();});
}
(async()=>{
 const backendPort=await freePort(),uiPort=await freePort(),ui='http://localhost:'+uiPort;
 const gateway=createGateway({backend:'http://127.0.0.1:'+backendPort,uiOrigin:ui,ttlMs:1000});
 await new Promise(r=>gateway.server.listen(0,'127.0.0.1',r));
 const node='http://localhost:'+gateway.server.address().port;
 const child=cp.spawn(swipl,['-f','none','-q','-s','Deployment/start_node.pl'],{cwd:root,env:{...process.env,WP_PORT:String(backendPort),WP_AUTH:'private',WP_PROFILE:'actor',WP_AUTHENTICATED_DEFAULT_CAPS:'execute',WP_WS_ALLOWED_ORIGINS:ui,WP_PUBLIC_URL:node},stdio:['ignore','ignore','pipe']});
 let stderr='';child.stderr.on('data',s=>stderr+=s);
 let checks=0;function check(value,label){assert.ok(value,label);checks++;console.log('PASS '+label);}
 try{
  let ready=false;for(let i=0;i<100;i++){try{ready=(await request('http://localhost:'+backendPort,'/healthz')).status===200;if(ready)break;}catch(e){}await sleep(50);}
  if(!ready)throw Error('Native node did not start: '+stderr.slice(-1000));
  let r=await request(node,'/node_info','GET',{Origin:ui});check(r.status===401&&r.headers['access-control-allow-origin']===ui&&r.headers['access-control-allow-credentials']==='true','signed-out API returns readable 401, no redirect');
  r=await request(node,'/node_info','GET',{Origin:'http://localhost:1'});check(r.status===403&&!r.headers['access-control-allow-origin'],'unlisted origin denied without CORS grant');
  r=await request(node,'/toplevel_spawn','OPTIONS',{Origin:ui,'Access-Control-Request-Method':'POST','Access-Control-Request-Headers':'content-type'});check(r.status===204,'JSON preflight needs no session cookie');
  r=await request(node,'/toplevel_spawn','OPTIONS',{Origin:ui,'Access-Control-Request-Method':'POST','Access-Control-Request-Headers':'X-Web-Prolog-User'});check(r.status===403,'identity-header preflight denied');
  r=await request(node,'/node_info','GET',{Origin:ui,'X-Web-Prolog-User':'forged-admin','X-Web-Prolog-Capabilities':'admin'});check(r.status===401,'forged proxy identity cannot authenticate');
  r=await request(node,'/login','POST',{Origin:node});check(r.status===200,'node-origin login succeeds');
  const setCookie=r.headers['set-cookie'][0],cookie=setCookie.split(';')[0];check(setCookie.includes('HttpOnly')&&setCookie.includes('SameSite=Lax'),'test cookie is HttpOnly and same-site');
  const headers={Origin:ui,Cookie:cookie};
  r=await request(node,'/node_info','GET',headers);const info=r.json();check(r.status===200&&info.principal_id==='cdn-test-user'&&info.principal_execution,'authenticated identity reaches real private native node');
  r=await request(node,'/node_info','GET',{...headers,'X-Web-Prolog-User':'forged-admin','X-Web-Prolog-Capabilities':'admin'});check(r.json().principal_id==='cdn-test-user','signed-in client identity headers are replaced by verified identity');
  r=await request(node,'/call?goal=member(X,%5Ba,b%5D)&format=json&limit=1','GET',headers);check(r.status===200&&r.json().data[0].X==='a','authenticated stateless native execution');
  const ws=await upgrade(node,ui,cookie);check(ws.status===101,'authenticated allowed-origin WebSocket upgrade');
  const denied=await upgrade(node,'http://localhost:1',cookie);check(denied.status===403,'authenticated cookie cannot bypass WebSocket origin policy');
  r=await request(node,'/logout','POST',{...headers,Origin:node});check(r.status===200,'node-origin logout succeeds');
  await sleep(20);check(ws.socket.destroyed,'logout revokes fixture WebSocket connection');
  r=await request(node,'/node_info','GET',headers);check(r.status===401,'logged-out cookie cannot reconnect');
  check((await upgrade(node,ui,cookie)).status===401,'logged-out cookie cannot upgrade WebSocket');
  r=await request(node,'/login','POST',{Origin:node});const expiring=r.headers['set-cookie'][0].split(';')[0];
  const expWs=await upgrade(node,ui,expiring);check(expWs.status===101,'fresh session reconnects after logout');
  await sleep(1300);check(expWs.socket.destroyed,'fixture expiry closes its active WebSocket');
  r=await request(node,'/node_info','GET',{Origin:ui,Cookie:expiring});check(r.status===401,'expired session no longer authorizes HTTP');
  console.log(JSON.stringify({checks,failed:0,counts:gateway.counts}));
 }finally{
  await gateway.close();child.kill('SIGTERM');
  const timer=setTimeout(()=>child.kill('SIGKILL'),3000);timer.unref();await new Promise(r=>child.once('exit',r));clearTimeout(timer);
 }
})().catch(e=>{console.error(e.message);process.exitCode=1;});
