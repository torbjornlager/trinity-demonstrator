#!/usr/bin/env python3
"""Run the actual tutorial source/calls against explicitly selected endpoints."""
import argparse,html,json,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def cases():
 out=[]
 for page in ['tutorial.html','actor-profile-tutorial.html']:
  text=(ROOT/'web'/page).read_text()
  def pre(name):
   return html.unescape(re.search('<pre id="'+name+'">(.*?)</pre>',text,re.S)[1]).strip()
  def query(name):return pre(name).removeprefix('?-').strip().removesuffix('.')
  out.append(dict(item=page+' fridge',source=pre('epa-fridge-api-source'),queries=[query('epa-fridge-api-spawn'),query('epa-fridge-api-store')+',Response==ok',query('epa-fridge-api-take')+',Response==ok(cheese)',query('epa-fridge-api-stop')],expected_errors=[]))
  out.append(dict(item=page+' ping',source=pre('epa-pingpong-source'),queries=[query('epa-pingpong-run')+',sleep(0.2),flush'],expected_errors=[],stdout=['Ping finished.','Pong finished.']))
  out.append(dict(item=page+' recovery',source=pre('srv-fridge-source'),queries=[query('srv-spawn'),query('srv-store-1'),query('srv-bad-call'),query('srv-after-recovery')+',Response==ok',query('srv-halt')],expected_errors=[2] if page.startswith('actor') else []))
  if page=='actor-profile-tutorial.html':
   out.append(dict(item=page+' delayed promise',source='',queries=[query('rpc-promise-timeout')+',Answer==timeout','yield($Ref,Later,[timeout(3)]),Later=success([_],false)',query('rpc-promise-poll')+',Answer=success([_],false)'],expected_errors=[],stdout=['Still waiting...']))
 return out

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--write-cases',type=Path);p.add_argument('--config',type=Path);p.add_argument('--session-module',type=Path);p.add_argument('--report',type=Path);a=p.parse_args()
 if a.write_cases:a.write_cases.write_text(json.dumps(cases(),indent=2)+'\n');return
 sys.path.insert(0,str(a.session_module));import acceptance_session as client
 rows=[]
 for node in json.loads(a.config.read_text()):
  for c in cases():
   s=client.Session(node['ws'],node['origin'],source=c['source'],headers=node.get('headers',()))
   try:
    output=''
    for i,q in enumerate(c['queries']):
     r=s.call(q);expected='error' if i in c['expected_errors'] else 'success';assert r['event']['type']==expected,(node['name'],c['item'],i,r)
     if expected=='error':assert 'server_down(false)' in str(r['event']),r
     output+=r['stdout'];rows.append(dict(node=node['name'],item=c['item'],query_index=i,result='pass',observation=r))
    for word in c.get('stdout',[]):assert word in output,(node['name'],c['item'],output)
   finally:s.close()
   a.report.write_text(json.dumps(rows,indent=2)+'\n');print(node['name'],c['item'],'pass',flush=True)
if __name__=='__main__':main()
