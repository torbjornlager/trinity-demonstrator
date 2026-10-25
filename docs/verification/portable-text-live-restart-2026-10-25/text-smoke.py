from pathlib import Path
import json,sys
from urllib.request import urlopen
from urllib.parse import urlencode
sys.path.insert(0,'../trinity-conformance/runner');import run as wire
OUT=Path(__file__).resolve().parent;rows=[]
# Match browser JSON.stringify: raw Unicode, avoiding the separately reported
# Trealla surrogate-escape JSON-library diagnostic (#1181).
def browser_json(ws,value):
 ws._send_frame(0x1,json.dumps(value,ensure_ascii=False,separators=(',',':')).encode('utf-8'))
wire.WebSocket.send_json=browser_json
def http(url,goal):
 with urlopen(url+'/call?'+urlencode(dict(goal='('+goal+')',template='(Outcome)',format='prolog',limit=1)),timeout=10) as r:return r.read().decode()
for name,url in [('n3','http://localhost:3053'),('n5','http://localhost:3060')]:
 for label,goal in [('Unicode characters','"hé😀"==[h,é,\'😀\'],Outcome=ok'),('empty text','""==[],Outcome=ok')]:
  result=http(url,goal);passed='success([ok],false)' in result;rows.append(dict(node=name,check=label,passed=passed,result=result));assert passed,result
 with wire.Harness(wire.Candidate(url.replace('http:','ws:')+'/ws','actor',10,None,url,False,())) as h:
  source='private_text("hé😀").'
  h.spawn_shell('[session(true),src_text('+"'"+source+"'"+')]')
  try:
   goal='private_text(T),T==[h,é,\'😀\'],self(Me),spawn(Me ! copied(T),P,[monitor(true)]),receive({copied(C)->true},[timeout(2)]),C==T,receive({down(P,P,true)->true},[timeout(2)]),Outcome=ok'
   h.call(goal,'[template(Outcome),format(prolog),limit(1)]')
   for _ in range(20):
    e=h.recv()
    if e.get('type') in ['success','failure','error']:break
   passed=e.get('data')==['ok'];rows.append(dict(node=name,check='private source and actor copying',passed=passed,result=e));assert passed,e
  finally:h.halt()
for label,goal in [('model character prompt','model_answer("hé😀",error(unavailable)),Outcome=ok'),('model invalid atom','model_answer(abc,error(invalid_prompt)),Outcome=ok'),('Jev character prompt','jev_deployment_observation("hé😀",unavailable(configuration)),Outcome=ok'),('Jev invalid codes','jev_deployment_observation([97],unavailable(invalid_text)),Outcome=ok')]:
 result=http('http://localhost:3053',goal);passed='success([ok],false)' in result;rows.append(dict(node='n3',check=label,passed=passed,result=result));assert passed,result
(OUT/'text-smoke.json').write_text(json.dumps(rows,indent=2)+'\n');print(len(rows),'text checks passed')
