from pathlib import Path
import subprocess,os,json,time,urllib.request,socket
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[2];NATIVE=ROOT.parent/'swi-prolog-node'
EXE=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/install/bin/swipl'
with socket.socket()as s:s.bind(('127.0.0.1',51853))
shared=[ROOT/'Deployment'/name for name in ['shared_db_common.pl','shared_db_actor_common.pl','shared_db_n3.pl']]
options="[tcp_socket(Socket),profile(actor),sandbox(blacklist),auth(open),ws_allowed_origins(['http://localhost:51853','http://127.0.0.1:51853']),tutorial_sections([behaviours,distributed_actor,local_actor,statecharts,toplevels]),"+','.join("load_shared_db_file('"+str(p)+"')"for p in shared)+']'
goal=f"use_module('{NATIVE}/prolog/web_prolog/node.pl'),set_setting(http:public_host,localhost),set_setting(http:public_port,51853),set_setting(http:public_scheme,http),use_module(library(socket)),tcp_socket(Socket),tcp_bind(Socket,ip(127,0,0,1):51853),tcp_listen(Socket,128),node:node(51853,{options}),thread_get_message(stop)"
cmd=[str(EXE),'-f','none','-q','-g',goal];env=dict(os.environ,WP_ASSET_ROOT=str(ROOT),WP_WASM_SOURCE_DIR=str(ROOT/'prolog/web_prolog/wasm'))
for k in ['SWI_HOME_DIR','SWIPL_HOME_DIR']:env.pop(k,None)
with (OUT/'ui-node.log').open('w')as log:p=subprocess.Popen(cmd,cwd=NATIVE,env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
(OUT/'ui-node.pid').write_text(str(p.pid)+'\n');(OUT/'ui-node-command.json').write_text(json.dumps({'command':cmd,'pid':p.pid,'environment':{'WP_ASSET_ROOT':env['WP_ASSET_ROOT'],'WP_WASM_SOURCE_DIR':env['WP_WASM_SOURCE_DIR']}},indent=2)+'\n')
for _ in range(100):
 if p.poll()is not None:raise RuntimeError('temporary node exited')
 try:
  with urllib.request.urlopen('http://localhost:51853/readyz',timeout=.5)as r:assert r.status==200;break
 except OSError:time.sleep(.1)
else:raise RuntimeError('temporary node not ready')
print('temporary UI node ready',p.pid)
