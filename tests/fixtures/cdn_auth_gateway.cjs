/* Loopback-only authentication/CORS fixture, NOT a production auth service.
   It proxies real execution to a private native node. No credentials are logged. */
'use strict';
const http=require('node:http'),crypto=require('node:crypto');
function createGateway({backend,uiOrigin,ttlMs=300000,publicMode=false}) {
 const target=new URL(backend),allowed=new URL(uiOrigin).origin;
 if(!['localhost','127.0.0.1'].includes(target.hostname))throw Error('Fixture backend must be loopback');
 if(new URL(uiOrigin).href!==allowed+'/')throw Error('UI origin must be an exact origin');
 const sessions=new Map(),counts={preflight:0,deniedOrigin:0,unauthenticated:0,http:0,ws:0,login:0,logout:0,expired:0};
 const api=new Set(['/version','/node_info','/call','/toplevel_spawn','/toplevel_call','/toplevel_next','/toplevel_poll','/toplevel_stop','/toplevel_abort','/toplevel_halt','/toplevel_respond']);
 const sockets=new Set();
 function own(req){return 'http://'+req.headers.host;}
 function permitted(req){return !req.headers.origin||req.headers.origin===allowed||req.headers.origin===own(req);}
 function cors(req){return req.headers.origin===allowed?{'Access-Control-Allow-Origin':allowed,'Access-Control-Allow-Credentials':'true','Vary':'Origin'}:{'Vary':'Origin'};}
 function reply(req,res,status,data){res.writeHead(status,{...cors(req),'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(data));}
 function cookie(req){const m=/(?:^|;\s*)cdn_fixture_session=([a-f0-9]+)/.exec(req.headers.cookie||'');return m&&m[1];}
 function expire(id){const s=sessions.get(id);if(!s)return;sessions.delete(id);for(const socket of s.sockets)socket.destroy();}
 function session(req){const id=cookie(req),s=sessions.get(id);if(s&&s.until>Date.now())return s;if(s){counts.expired++;expire(id);}return null;}
 function headers(req,s){
  const h={...req.headers,host:req.headers.host};
  for(const name of Object.keys(h))if(/^(x-web-prolog-|x-auth|x-forwarded-|forwarded$|authorization$|cookie$)/i.test(name))delete h[name];
  if(s)h['x-web-prolog-user']='cdn-test-user';
  return h;
 }
 const server=http.createServer((req,res)=>{
  const path=new URL(req.url,own(req)).pathname;
  if(!permitted(req)){counts.deniedOrigin++;reply(req,res,403,{message:'Origin denied'});return;}
  if(req.method==='OPTIONS'){
   counts.preflight++;
   const method=req.headers['access-control-request-method'];
   const names=(req.headers['access-control-request-headers']||'').toLowerCase().split(',').map(x=>x.trim()).filter(Boolean);
   if(!api.has(path)||!['GET','POST'].includes(method)||names.some(x=>x!=='content-type')){reply(req,res,403,{message:'Preflight denied'});return;}
   res.writeHead(204,{...cors(req),'Access-Control-Allow-Methods':'GET, POST','Access-Control-Allow-Headers':'Content-Type','Cache-Control':'no-store'});res.end();return;
  }
  if(['/login','/logout','/expire'].includes(path)){
   // Top-level node-origin form: no passwords or external provider are involved.
   if(req.method==='POST'){
    if(req.headers.origin!==own(req)){reply(req,res,403,{message:'Node-origin form required'});return;}
    let setCookie;
    if(path==='/login'){
     const id=crypto.randomBytes(32).toString('hex');sessions.set(id,{until:Date.now()+ttlMs,sockets:new Set()});counts.login++;
     setCookie='cdn_fixture_session='+id+'; Path=/; HttpOnly; SameSite=Lax';
    }else {expire(cookie(req));counts[path==='/logout'?'logout':'expired']++;setCookie='cdn_fixture_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0';}
    res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store','Set-Cookie':setCookie});res.end('<title>Test node session</title><h1>'+ (path==='/login'?'Signed in':'Signed out')+'</h1><p>Return to the static demonstrator and choose Reconnect.</p>');return;
   }
   res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});
   const label=path==='/login'?'Sign in as test user':path==='/logout'?'Sign out of test node':'Expire test session';
   res.end('<title>Test node session</title><h1>Loopback test node session</h1><p>This is a disposable login fixture, not a real identity provider.</p><form method="post" action="'+path+'"><button>'+label+'</button></form>');return;
  }
  if(!api.has(path)){reply(req,res,404,{message:'Route unavailable from static UI'});return;}
  const s=session(req);
  if(!publicMode&&!s&&path!=='/version'){counts.unauthenticated++;reply(req,res,401,{message:'Authentication required; sign in to the node and Reconnect.'});return;}
  counts.http++;
  const upstream=http.request({hostname:target.hostname,port:target.port,path:req.url,method:req.method,headers:headers(req,s)},up=>{
   res.writeHead(up.statusCode,{...up.headers,...cors(req),'Cache-Control':'no-store'});up.pipe(res);
  });upstream.on('error',()=>{if(!res.headersSent)reply(req,res,502,{message:'Backend unavailable'});else res.destroy();});req.pipe(upstream);
 });
 server.on('upgrade',(req,socket,head)=>{
  const path=new URL(req.url,own(req)).pathname,s=session(req);
  function deny(code,message){socket.end('HTTP/1.1 '+code+' '+message+'\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');}
  if(path!=='/ws'||!permitted(req)){counts.deniedOrigin++;deny(403,'Forbidden');return;}
  if(!publicMode&&!s){counts.unauthenticated++;deny(401,'Unauthorized');return;}
  const upstream=http.request({hostname:target.hostname,port:target.port,path:req.url,method:'GET',headers:headers(req,s)});
  upstream.on('upgrade',(response,peer,extra)=>{
   counts.ws++;sockets.add(socket);if(s)s.sockets.add(socket);
   socket.write('HTTP/1.1 101 Switching Protocols\r\n'+Object.entries(response.headers).map(([k,v])=>k+': '+v).join('\r\n')+'\r\n\r\n');
   if(extra.length)socket.write(extra);if(head.length)peer.write(head);
   peer.pipe(socket);socket.pipe(peer);
   socket.on('close',()=>{peer.destroy();sockets.delete(socket);if(s)s.sockets.delete(socket);});peer.on('error',()=>socket.destroy());socket.on('error',()=>peer.destroy());
  });
  upstream.on('response',r=>{r.resume();deny(r.statusCode,'Rejected');});upstream.on('error',()=>socket.destroy());upstream.end();
 });
 const timer=setInterval(()=>{for(const [id,s]of sessions)if(s.until<=Date.now()){counts.expired++;expire(id);}},200);timer.unref();
 return {server,counts,close(){clearInterval(timer);for(const s of sockets)s.destroy();for(const id of sessions.keys())expire(id);return new Promise(resolve=>server.close(resolve));}};
}
module.exports={createGateway};
if(require.main===module){
 const [backend,uiOrigin,port='58426']=process.argv.slice(2);const g=createGateway({backend,uiOrigin});
 g.server.listen(Number(port),'127.0.0.1',()=>console.log(JSON.stringify({node:'http://localhost:'+g.server.address().port,uiOrigin})));
 process.on('SIGTERM',()=>g.close().then(()=>process.exit()));
}
