"""Executed only inside the disposable public WebSocket/N1 fixture."""
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from pathlib import Path
import json,sys
import wire,audit_client
from audit_budget import RequestBudget
audit_client.codec=lambda:wire
mode=sys.argv[1];origin='https://n5.elfenbenstornet.se';rows=[]
sink=audit_client.JsonlReporter('/tmp/'+mode+'-stages.jsonl');budget=RequestBudget(50)
class Blocks(HTMLParser):
 def __init__(self):super().__init__();self.key=None;self.blocks={}
 def handle_starttag(self,t,a):
  if t=='pre':self.key=dict(a).get('id');self.blocks[self.key]=''
 def handle_endtag(self,t):
  if t=='pre':self.key=None
 def handle_data(self,d):
  if self.key:self.blocks[self.key]+=d
p=Blocks();p.feed(Path('/tmp/profile.html').read_text())
query=lambda k:p.blocks[k].strip().removeprefix('?-').strip().removesuffix('.')
def session():return audit_client.Session(origin.replace('https:','wss:')+'/ws',origin,query_timeout=6,reporter=sink)
source_call="rpc('https://n1.elfenbenstornet.se',mortal(X),[src_text(\"mortal(Who) :- human(Who).\")])"
if mode=='before':
 s=session()
 try:
  try:s.call(source_call);raise AssertionError('stalled public route unexpectedly completed')
  except audit_client.StageFailure as e:
   assert e.report['outcome']=='local_watchdog_timeout',e.report;rows.append(e.report)
 finally:assert s.close()
 assert s.timings[-1]['stage']=='socket_cleanup' and not s.timings[-1]['halt_attempted']
else:
 def lane(i):
  result=[]
  for rep in range(10):
   s=session()
   try:
    for case,q,remote in [('source-transfer',source_call,True),('initial-timeout',query('rpc-promise-timeout'),True),('later-yield','yield($Ref,Later,[timeout(3)])',False),('poll',query('rpc-promise-poll'),True)]:
     if remote:budget.acquire()
     r=s.call(q);assert r['event']['type']=='success',r
     if case=='initial-timeout':assert r['event']['data'][0]['Answer']=='timeout',r
     if case=='later-yield':assert r['event']['data'][0]['Later'].startswith('success('),r
     if case=='poll':assert r['event']['data'][0]['Answer'].startswith('success('),r;assert 'Still waiting' in r['stdout'],r
     result.append(dict(lane=i,repetition=rep,case=case,observation=r,timing=s.timings[-1]))
   finally:assert s.close()
  return result
 with ThreadPoolExecutor(max_workers=2) as pool:
  for group in pool.map(lane,[0,1]):rows.extend(group)
 assert len(rows)==80
 # Exercise the public TLS/proxy handshake independently of RPC quotas.
 def handshakes(lane):
  for rep in range(200):
   w=wire.WebSocket(origin.replace('https:','wss:')+'/ws',10,None,origin,False,())
   try:
    w.send_json(dict(command='transport_hello',version=1,browser_pids=True,io_ack=False))
    assert w.recv_json()['type']=='transport_welcome'
   finally:w.close()
  return 200
 with ThreadPoolExecutor(max_workers=2) as pool:
  assert sum(pool.map(handshakes,[0,1]))==400
print(json.dumps(dict(result='pass',mode=mode,observations=rows),indent=2))
