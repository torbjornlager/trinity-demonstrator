"""Anonymous checks against public production endpoints, with owned sessions only."""
import http.cookiejar,json,re,secrets,urllib.request,urllib.parse,os
from pathlib import Path
P=Path(__file__).resolve().parent;rows=[]
URLS=json.loads(os.environ.get('CONTEXT_SMOKE_URLS','{}'))
def node_url(node):return URLS.get(node,'https://'+node+'.elfenbenstornet.se')
def record(label,data):
 rows.append(dict(label=label,status='pass',url=node_url(node),observed=data));(P/'smoke/http-context.json').write_text(json.dumps(rows,indent=2)+'\n');print(label,'pass',flush=True)
def fresh(node,goal,template):
 params=dict(goal='('+goal+')',template=template,limit=1,format='prolog')
 with urllib.request.urlopen(node_url(node)+'/call?'+urllib.parse.urlencode(params),timeout=10) as r:return r.read().decode()
for node in ['n2','n3','n4','n5']:
 # The producer is the existing public relation node; no owner privileges are needed.
 created=fresh(node,"promise('https://n1.elfenbenstornet.se',true,R,[template(mark)])",'R')
 m=re.fullmatch(r'success\(\[(\d+)\],false\)\.',re.sub(r'\s+','',created));assert m,created
 ref=m[1];seen=fresh(node,f'catch(yield({ref},A,[timeout(1)]),E,A=error(E))','A')
 assert 'existence_error(promise,'+ref+')' in re.sub(r'\s+','',seen),seen
 record(node+'-fresh-http-isolated',dict(created=created,foreign_request=seen))
# The SWI retained HTTP API is public at ISOTOPE and ACTOR. Keep two anonymous cookies separate.
for node in ['n2','n3','n4']:
 sessions=[];clients={};observed={}
 def post(route,params,opener=None):
  body=json.dumps(params).encode() if route=='toplevel_spawn' else urllib.parse.urlencode(dict(params,format='json')).encode()
  req=urllib.request.Request(node_url(node)+'/'+route,data=body,headers={'Content-Type':'application/json' if route=='toplevel_spawn' else 'application/x-www-form-urlencoded'})
  with (opener or clients[params['pid']]).open(req,timeout=12) as r:return json.load(r)
 def call(pid,goal):return post('toplevel_call',dict(pid=pid,goal='('+goal+'),AuditCheck=passed',limit=1))
 try:
  for _ in range(2):
   opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
   pid=post('toplevel_spawn',dict(options='[session(true)]'),opener)['pid'];sessions.append(pid);clients[pid]=opener
  made=call(sessions[0],"promise('https://n1.elfenbenstornet.se',true,R,[template(mark)])");observed['created']=made
  value=made['data'][0];ref=str(value['R']);assert ref.isdigit(),made
  observed['foreign_yield']=call(sessions[1],f'catch(yield({ref},_,[timeout(0)]),error(existence_error(promise,{ref}),_),Missing=true),Missing==true')
  observed['foreign_cleanup']=call(sessions[1],f'promise_cleanup({ref})')
  observed['owner_collect']=call(sessions[0],f'yield({ref},success([mark],false),[timeout(5)])')
  assert all(v.get('type')=='success' and v.get('more') is False for v in observed.values()),observed
  record(node+'-anonymous-retained-http',observed)
 finally:
  for pid in sessions:post('toplevel_halt',dict(pid=pid))
