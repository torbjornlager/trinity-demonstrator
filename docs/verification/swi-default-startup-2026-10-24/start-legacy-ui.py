from pathlib import Path
import subprocess,json,urllib.request,time,os
ROOT=Path(__file__).resolve().parents[3];OUT=Path(__file__).resolve().parent;WORK=Path.home()/'.local/share/trinity-runtime-tests/swi-default-startup-2026-10-24';NATIVE=ROOT.parent/'swi-prolog-node'
port=51857
files=[ROOT/'Deployment/shared_db_common.pl',ROOT/'Deployment/shared_db_actor_common.pl',ROOT/'Deployment/shared_db_n3.pl'];options=["tcp_socket(Socket)","profile(actor)","sandbox(blacklist)","auth(open)","ws_allowed_origins(['http://localhost:51857','http://127.0.0.1:51857'])","tutorial_sections([local_actor,toplevels,distributed_actor,behaviours,statecharts])"]+[f'load_shared_db_file({str(p)!r})' for p in files]
origins=OUT/'legacy-ui-origins.json';goal="use_module(library(http/json)),true,findall(_{module:M,file:F},module_property(M,file(F)),Rows),setup_call_cleanup(open("+repr(str(origins))+",write,F),json_write_dict(F,Rows,[]),close(F)),set_setting(http:public_host,localhost),set_setting(http:public_port,51857),set_setting(http:public_scheme,http),use_module(library(socket)),tcp_socket(Socket),tcp_bind(Socket,ip(127,0,0,1):51857),tcp_listen(Socket,128),node(51857,["+','.join(options)+"]),thread_get_message(stop)"
cmd=[str(WORK/'runtime/bin/swipl'),'-f','none','-q','-s',str(ROOT/'load.pl'),'-g',goal,'-t','halt']
log=(OUT/'legacy-ui-node.log').open('w');p=subprocess.Popen(cmd,cwd=WORK,env=dict(os.environ,WP_NATIVE_MODE='legacy'),stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True);(OUT/'legacy-ui-node.json').write_text(json.dumps({'pid':p.pid,'port':port,'command':cmd,'cwd':str(WORK)},indent=2)+'\n')
for _ in range(100):
 if p.poll() is not None:raise RuntimeError('Temporary node exited')
 try:
  with urllib.request.urlopen('http://localhost:51857/portal',timeout=.3) as r:assert r.status==200
  print('Temporary legacy node ready',p.pid);break
 except Exception:time.sleep(.1)
else:raise RuntimeError('Readiness timeout')
