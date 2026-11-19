"""Post-cutover public N5 tests; every failed assertion rejects the deployment."""
import json,subprocess,sys,time
from pathlib import Path
P=Path(__file__).resolve().parent;R=P.parents[1];C=Path('/Users/lager/trinity-conformance');rows=[]
def save(): (P/'live-smoke-summary.json').write_text(json.dumps(rows,indent=2)+'\n')
def run(label,command):
 with (P/(label+'.log')).open('w') as out:r=subprocess.run(list(map(str,command)),cwd=R,stdout=out,stderr=subprocess.STDOUT,timeout=240)
 rows.append(dict(label=label,exit_code=r.returncode));save()
 if r.returncode:raise RuntimeError(label+' failed')
 print(label,'pass',flush=True)
run('live-naming',[sys.executable,C/'adapters/client_naming.py','--ws-url','wss://n5.elfenbenstornet.se/ws','--candidate','live-n5','--session-interval','2','--output',P/'live-naming.json'])
for suite,url in [('isobase-http','https://n5.elfenbenstornet.se'),('local-naming','wss://n5.elfenbenstornet.se/ws'),('interop-actor','wss://n5.elfenbenstornet.se/ws')]:
 command=[sys.executable,C/'runner/baseline.py','--manifest',C/'cases'/(suite+'-0.1.json'),'--url',url,'--candidate','live-n5','--profile','actor','--session-interval','2','--report',P/('live-'+suite+'.json')]
 if suite=='interop-actor':command+=['--peer','https://n3.elfenbenstornet.se']
 run('live-'+suite,command)
run('live-actor-core',[sys.executable,C/'runner/run.py','--manifest',C/'cases/actor-core-0.1.json','--ws-url','wss://n5.elfenbenstornet.se/ws','--candidate','live-n5','--advertised-profile','actor','--origin','https://n5.elfenbenstornet.se','--session-interval','2','--report',P/'live-actor-core.json'])
run('live-linda',[sys.executable,R/'tools/test_linda_service.py','--ws-url','wss://n5.elfenbenstornet.se/ws','--origin','https://n5.elfenbenstornet.se','--conformance-root',C])
sys.path.insert(0,str(C/'runner'));from run import Candidate,Harness,set_session_interval
set_session_interval(2)
with Harness(Candidate('wss://n5.elfenbenstornet.se/ws','actor',15,None,'https://n5.elfenbenstornet.se',False,())) as h:
 h.spawn_shell()
 for label,goal in [('n5-to-n1-source','rpc(\'https://n1.elfenbenstornet.se\',double(21,R),[src_text("double(X,Y) :- Y is X*2.")]),R=42'),('n5-n2-n4-rpc',"findall(X,rpc('https://n2.elfenbenstornet.se',mortal(X)),Xs),sort(Xs,[aristotle,plato,socrates])")]:
  h.call(goal,'[limit(1)]');result=h.recv_type('success',limit=64);assert result.get('more') is False,result
  rows.append(dict(label=label,exit_code=0));save();print(label,'pass',flush=True)
 h.halt()
