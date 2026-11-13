"""Runs only inside the isolated topology fixture, using its pinned wire codec."""
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from pathlib import Path
import json,sys,time
import wire,audit_client
audit_client.codec=lambda:wire
origin=sys.argv[1];mode=sys.argv[2];rows=[]
class Blocks(HTMLParser):
 def __init__(self):super().__init__();self.current=None;self.blocks={}
 def handle_starttag(self,t,a):
  if t=='pre':self.current=dict(a).get('id');self.blocks[self.current]=''
 def handle_endtag(self,t):
  if t=='pre':self.current=None
 def handle_data(self,s):
  if self.current:self.blocks[self.current]+=s
p=Blocks();p.feed(Path('/tmp/tutorial.html').read_text());calls=[(k,p.blocks[k].strip().removeprefix('?-').strip().removesuffix('.')) for k in ['rpc1','promise1','promise2','rpc2']]
reporter=audit_client.JsonlReporter('/tmp/stages.jsonl')
def session():return audit_client.Session(origin.replace('http:','ws:')+'/ws',origin,query_timeout=6,reporter=reporter)
def run(rep,phase):
 s=session();out=[]
 try:
  for case,q in calls:
   r=s.call(q);out.append(dict(phase=phase,repetition=rep,case=case,observation=r,timing=s.timings[-1]));assert r['event']['type']=='success',r
   assert not any(str(v).startswith('error(') for d in r['event'].get('data',[]) for v in d.values()),r
   if case=='promise2':
    answer=r['event']['data'][0]['Answer'];assert answer.startswith('success(') and all(name in answer for name in ['socrates','plato','aristotle']),r
 finally:closed=s.close()
 assert closed,s.timings[-1]
 return out
if mode=='before':
 s=session()
 try:
  for q in ["rpc('https://n2.elfenbenstornet.se',mortal(X))","promise('https://n2.elfenbenstornet.se',mortal(X),Ref)",'yield($Ref,Answer)']:
   r=s.call(q);rows.append(dict(observation=r,timing=s.timings[-1]))
 finally:closed=s.close()
 assert closed,s.timings[-1]
 assert 'resource_error(time)' in str(rows[0]['observation']) and 'resource_error(time)' in str(rows[-1]['observation']),rows
 assert all(not r['timing']['watchdog']['fired'] for r in rows)
else:
 for i in range(23):rows.extend(run(i,'quiet'))
 print('Quiet phase passed; waiting for the unchanged 60-second request window',file=sys.stderr,flush=True)
 for _ in range(61):time.sleep(1)
 def lane(i):
  out=[]
  for rep in range(20):out.extend(run(rep,'parallel-'+str(i)))
  return out
 with ThreadPoolExecutor(max_workers=2) as pool:
  for out in pool.map(lane,[0,1]):rows.extend(out)
 for i in range(9):
  s=session();assert s.close()
 assert len(rows)==252
print(json.dumps(dict(result='pass',mode=mode,observations=rows),indent=2))
