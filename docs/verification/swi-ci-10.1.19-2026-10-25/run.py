#!/usr/bin/env python3
"""Check the separately extracted official release; never install or restart."""
import json, os, signal, subprocess, time
from pathlib import Path
OUT=Path(__file__).resolve().parent
ROOT=OUT.parents[2]
SWIPL=json.loads((OUT/'runtime.json').read_text())['wrapper']
env=os.environ.copy()
env['SWIPL']=SWIPL
env['WP_NATIVE_MODE']='legacy'
env.pop('WP_EXPERIMENTAL_TEXT',None)
rows=[]
def run(label,command,seconds=360):
    start=time.monotonic()
    with (OUT/(label+'.log')).open('w') as log:
        p=subprocess.Popen(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        timed_out=False
        try:code=p.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            timed_out=True
            os.killpg(p.pid,signal.SIGTERM)
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGKILL);p.wait()
            code=124
    row=dict(label=label,command=command,exit_code=code,timeout=timed_out,watchdog_seconds=seconds,seconds=round(time.monotonic()-start,3))
    rows.append(row);(OUT/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print(row,flush=True)
    return code==0
if not run('prerequisite',[SWIPL,'-f','none','-q','-s','tests/tiers/receive_handoff_tests.pl','-g','run_tests(receive_handoff)','-t','halt'],30):
    raise SystemExit('engine prerequisite failed')
run('libraries',[SWIPL,'-f','none','-q','-g',"current_prolog_flag(version_data,swi(10,1,19,_)),use_module(library(pcre)),use_module(library(sgml)),use_module(library(http/http_open)),use_module(library(ssl)),use_module(library(crypto)),halt"])
for tier in ['LINT','T0','T1','T2','T3','T4','T5']:
    run(tier,['bash','tools/test.sh',tier])
raise SystemExit(int(any(r['exit_code']!=0 for r in rows)))
