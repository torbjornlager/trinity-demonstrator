import json,re,sys,time,importlib.util,hashlib,socket
from pathlib import Path
from urllib.request import urlopen
from urllib.parse import quote
P=Path(__file__).resolve().parent;R=P.parents[1]
sys.path.insert(0,'/Users/lager/trinity-conformance/runner');from run import Candidate,Harness,prolog_quote_atom,set_session_interval
spec=importlib.util.spec_from_file_location('exercise_checker',R/'tools/test_open_exercises.py');checker=importlib.util.module_from_spec(spec);spec.loader.exec_module(checker)
set_session_interval(1.5);rows=[]
for node in ['n3','n4']:
 url='https://'+node+'.elfenbenstornet.se'
 for number,name in [(13,'13 parallel.pl'),(16,'16 fridge_server.pl')]:
  path='/examples/actors/'+name
  with urlopen(url+quote(path,safe='/'),timeout=8) as f:source=f.read().decode()
  bindings={}
  with Harness(Candidate(url.replace('https:','wss:')+'/ws','actor',15,None,url,False,())) as h:
   h.spawn_shell('[session(true),src_text('+prolog_quote_atom(source)+')]')
   for i,query in enumerate(checker.queries(source),1):
    query=re.sub(r'\$([A-Z][A-Za-z0-9_]*)',lambda m:bindings[m[1]],query)
    h.call(query,'[limit(1),once(true)]');events=[];deadline=time.monotonic()+15;read=h.ws._recv_exact
    def bounded(count):
     remaining=deadline-time.monotonic()
     if remaining<=0:raise TimeoutError('15-second query deadline')
     h.ws.sock.settimeout(remaining);return read(count)
    h.ws._recv_exact=bounded
    try:
     while True:
      event=h.recv();events.append(event)
      if event.get('type') in ['success','failure','error'] and event.get('pid')==h.shell:break
      h.acknowledge_output(event)
    finally:h.ws._recv_exact=read
    expected='failure' if (number,i)==(13,2) else ('error' if (number,i) in [(13,3),(16,6)] else 'success')
    ok=event['type']==expected
    if expected=='error':ok=ok and ('type_error' if number==13 else 'server_down(false)') in str(event)
    if event['type']=='success' and event.get('data'):bindings.update(event['data'][0])
    rows.append(dict(node=node,path=path,query=i,source_sha256=hashlib.sha256(source.encode()).hexdigest(),goal=query,expected=expected,event=event,events=events,status='pass' if ok else 'fail'))
    (P/'smoke/live-exercises.json').write_text(json.dumps(dict(authentication='none',timeout_seconds=15,results=rows),indent=2)+'\n')
    assert ok,(node,path,i,event)
   h.halt()
  print(node,name,'passed',flush=True)
assert len(rows)==30,len(rows)
