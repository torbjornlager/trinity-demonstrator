#!/usr/bin/env python3
"""Serve the separate WASM candidate on an ephemeral loopback node."""
import sys,os,json,subprocess,socket,time,signal
from pathlib import Path
repo=Path(__file__).resolve().parents[3];out=Path(os.environ.get('TEST_WASM_EVIDENCE',Path(__file__).resolve().parent));out.mkdir(parents=True,exist_ok=True)
stage=Path.home()/'.local/share/trinity-runtime-tests/wasm-engine-8.2.5-2026-10-26'
selected=Path.home()/'.local/share/trinity-local-nodes/committed-adoption-2026-10-25'
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
web_root=Path(os.environ.get('TEST_WASM_WEB_ROOT',stage/'demonstrator'))
q=lambda x:"'"+str(x).replace("'","''")+"'"
goal=f"use_module(library(sgml)),use_module(library(option)),consult({q(selected/'native/load.pl')}),set_setting(node_assets:root,{q(web_root)}),set_setting(node_assets:wasm_directory,{q(selected/'demonstrator/.trinity/browser-prolog-38d86f5c618da3af')}),set_setting(http:public_host,'127.0.0.1'),set_setting(http:public_port,{port}),set_setting(http:public_scheme,http),use_module(library(socket)),tcp_socket(S),tcp_bind(S,ip(127,0,0,1):{port}),tcp_listen(S,128),node:node({port},[tcp_socket(S),profile(actor),sandbox(blacklist),auth(open)]),thread_get_message(stop)"
cmd=[str(Path.home()/'.local/share/trinity-runtimes/swi-current/bin/swipl'),'-f','none','-q','-g',goal]
env=dict(os.environ)
for k in ['SWI_HOME_DIR','SWIPL_HOME_DIR','WP_CONFIG_FILE','WP_ASSET_ROOT','WP_WASM_SOURCE_DIR','WP_NATIVE_MODE','WP_NATIVE_STATE','WP_EXPERIMENTAL_TEXT']:env.pop(k,None)
env['WP_EXPERIMENTAL_TEXT']='portable-text-0.2'
with (out/'ui-node.log').open('w') as log:
 proc=subprocess.Popen(cmd,env=env,cwd=selected/'native',stdout=log,stderr=log,start_new_session=True)
 try:
  for _ in range(150):
   if proc.poll() is not None:raise RuntimeError('Temporary node startup failed')
   try:
    with socket.create_connection(('127.0.0.1',port),timeout=.1):break
   except OSError:time.sleep(.05)
  else:raise TimeoutError('Temporary node startup')
  info=dict(url='http://127.0.0.1:'+str(port),pid=proc.pid,command=cmd,web_root=str(web_root),wasm_prolog_root=str(selected/'demonstrator/.trinity/browser-prolog-38d86f5c618da3af'));(out/'ui-node.json').write_text(json.dumps(info,indent=2)+'\n');print(info['url'],flush=True)
  while not (out/'STOP').exists():time.sleep(.5)
 finally:
  if proc.poll() is None:
   os.killpg(proc.pid,signal.SIGTERM)
   try:proc.wait(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
  (out/'ui-node-stopped.json').write_text(json.dumps(dict(pid=proc.pid,exit_code=proc.returncode))+'\n')
