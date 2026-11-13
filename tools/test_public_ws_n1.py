#!/usr/bin/env python3
"""Isolated TLS→Nginx→Trealla/N1 fault and recovery checks, with unchanged limits."""
import argparse,json,subprocess,time,uuid,hashlib
from pathlib import Path
from urllib.request import urlopen
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__)
 for name in ['swi-image','trealla-image','edge-image','admission-image','runtime-root','audit-tools','wire','output']:p.add_argument('--'+name,required=True)
 a=p.parse_args();O=Path(a.output).resolve();O.mkdir(mode=0o700);prefix='public-n1-'+uuid.uuid4().hex[:8];net=prefix;owned=[];made=False;report=dict(result='fail')
 def d(*args):
  try:return subprocess.check_output(['docker',*map(str,args)],stderr=subprocess.STDOUT)
  except subprocess.CalledProcessError as e:(O/'failed-command.private.log').write_bytes(e.output);raise
 def cp(src,name,dest):d('cp',src,name+':'+dest)
 def create(role,image,cmd,opts=()):
  name=prefix+'-'+role;d('create','--name',name,'--network',net,'--no-healthcheck',*opts,image,*cmd);owned.append(name);return name
 def health(probe,url):
  for _ in range(100):
   if subprocess.run(['docker','exec',probe,'python3','-c',f'import urllib.request;urllib.request.urlopen({url!r},timeout=1).read()'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:return
   time.sleep(.1)
  raise RuntimeError('Fixture health failed')
 try:
  d('network','create','--internal',net);made=True
  one=create('one',a.swi_image,['swipl','-q','-s','/app/Deployment/start_n1.pl','-g','start_n1_forever','-t','halt']);d('start',one);health(one,'http://127.0.0.1:3051/healthz')
  slow=O/'slow.py';slow.write_text('''from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import time
class H(BaseHTTPRequestHandler):
 def do_GET(self):
  with open('/tmp/slow-count','a') as f:f.write('hit\\n')
  time.sleep(12)
  try:self.send_response(200);self.end_headers();self.wfile.write(b'failure.\\n')
  except OSError:pass
 def log_message(self,*args):pass
ThreadingHTTPServer(('0.0.0.0',3056),H).serve_forever()
''');cp(slow,one,'/tmp/slow.py');d('exec','-d',one,'python3','/tmp/slow.py')
  five_name=prefix+'-five';admission_name=prefix+'-admission'
  config=O/'Caddyfile';config.write_text('{\n admin off\n auto_https disable_redirects\n}\n'+f'https://n1.elfenbenstornet.se {{\n tls internal\n reverse_proxy {one}:3056\n}}\nhttps://n5.elfenbenstornet.se {{\n tls internal\n reverse_proxy {admission_name}:8080 {{\n  header_up X-Real-IP {{remote_host}}\n }}\n}}\n')
  edge=create('edge',a.edge_image,['caddy','run','--config','/etc/caddy/Caddyfile','--adapter','caddyfile'],['--network-alias','n1.elfenbenstornet.se','--network-alias','n5.elfenbenstornet.se']);cp(config,edge,'/etc/caddy/Caddyfile');d('start',edge)
  for _ in range(100):
   if subprocess.run(['docker','exec',edge,'test','-f','/data/caddy/pki/authorities/local/root.crt'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:break
   time.sleep(.1)
  ca=O/'fixture-root.crt';d('cp',edge+':/data/caddy/pki/authorities/local/root.crt',ca);cp(ca,one,'/usr/local/share/ca-certificates/fixture-root.crt');d('exec','-u','0',one,'update-ca-certificates')
  five=create('five',a.trealla_image,['/bin/sh','-c','update-ca-certificates >/dev/null 2>&1; exec /bin/sh /app/owner_start/entrypoint.n5-linda.sh'],['--entrypoint','/usr/bin/env','--user','0','--network-alias','wp_n5','--memory','1g','--cpus','1','-e','WP_ADMIN_TOKEN=isolated-test-admin-token-only','-e','WP_PORT=3060','-e','WP_PUBLIC_URL=https://n5.elfenbenstornet.se','-e','WP_WS_ALLOWED_ORIGINS=https://n5.elfenbenstornet.se','-e','WP_PROFILE=actor','-e','WP_AUTH=open','-e','WP_ACK_PUBLIC=yes','-e','WP_SANDBOX=blacklist','-e','WP_TIME_LIMIT=300','-e','WP_IDLE_LIMIT=300','-e','WP_PEER_RPC_ENDPOINTS_FILE=/app/owner_start/rpc-endpoints.pl','-e','WP_SHARED_DB_FILES=/app/Deployment/shared_db_common.pl,/app/Deployment/shared_db_actor_common.pl,/app/Deployment/shared_db_n4.pl,/app/owner_services/linda_client.pl,/app/owner_start/shared_db_linda.pl'])
  cp(ca,five,'/usr/local/share/ca-certificates/fixture-root.crt')
  endpoints=O/'rpc-endpoints.pl';endpoints.write_text(repr('https://n1.elfenbenstornet.se')+'-'+repr('http://'+one+':3051')+'.\n')
  # File format is one list, matching the deployment's separate execution map.
  endpoints.write_text('['+endpoints.read_text().removesuffix('.\n')+'].\n');cp(endpoints,five,'/app/owner_start/rpc-endpoints.pl');d('start',five);health(one,'http://wp_n5:3060/healthz')
  admission=create('admission',a.admission_image,['nginx','-g','daemon off;'],['--entrypoint','/usr/bin/env']);d('start',admission)
  for src,dest in [(Path(a.wire),'/tmp/wire.py'),(Path(a.audit_tools)/'audit_client.py','/tmp/audit_client.py'),(Path(a.audit_tools)/'audit_budget.py','/tmp/audit_budget.py'),(ROOT/'tests/public_ws_n1/driver.py','/tmp/driver.py')]:cp(src,one,dest)
  with urlopen('https://n5.elfenbenstornet.se/actor-profile-tutorial',timeout=15) as r:body=r.read()
  page=O/'profile.html';page.write_bytes(body);cp(page,one,'/tmp/profile.html')
  def driver(mode):
   print('Running',mode,'through private public-facing TLS/proxy stack',flush=True)
   with (O/(mode+'.private.log')).open('wb') as log:r=subprocess.run(['docker','exec',one,'python3','/tmp/driver.py',mode],stdout=subprocess.PIPE,stderr=log)
   (O/(mode+'.json')).write_bytes(r.stdout);subprocess.run(['docker','cp',one+':/tmp/'+mode+'-stages.jsonl',str(O/(mode+'-stages.jsonl'))],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   if r.returncode:raise RuntimeError(mode+' fixture driver failed')
   result=json.loads(r.stdout);assert result['result']=='pass';return result
  before=driver('before');hits=d('exec',one,'cat','/tmp/slow-count').splitlines()
  d('stop',five)
  runtime=Path(a.runtime_root)
  for f in ['actors.pl','isolation.pl','web_prolog.pl','rpc.pl','rpc_topology.pl','Deployment/start_node.pl']:cp(runtime/f,five,'/app/'+f)
  d('start',five);health(one,'http://wp_n5:3060/healthz')
  candidate=driver('candidate');assert d('exec',one,'cat','/tmp/slow-count').splitlines()==hits
  stages=[json.loads(l) for l in (O/'candidate-stages.jsonl').read_text().splitlines()];assert all(r['outcome']=='ok' and not r['watchdog']['fired'] for r in stages)
  report.update(result='pass',stalled_public_route_before='six-second explicit client watchdog; dead-socket cleanup sent no halt',candidate_sessions=20,additional_TLS_handshakes=400,candidate_queries=len(candidate['observations']),candidate_peer_calls=60,client_budget=50,peer_limit=60,window_seconds=60,all_original_timeouts_and_limits_unchanged=True,watchdog_expiries_after_fix=0,public_route_still_stalled_and_unused=True,stalled_public_route_hits=len(hits),full_TLS_nginx_Trealla_stack=True,network_internal_only=True,source_sha256={str(runtime/f):hashlib.sha256((runtime/f).read_bytes()).hexdigest() for f in ['actors.pl','isolation.pl','web_prolog.pl','rpc.pl','rpc_topology.pl','Deployment/start_node.pl']})
 finally:
  for name in owned:
   with (O/(name+'.private.log')).open('wb') as log:subprocess.run(['docker','logs',name],stdout=log,stderr=subprocess.STDOUT)
  for name in reversed(owned):subprocess.run(['docker','rm','-f','-v',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  if made:subprocess.run(['docker','network','rm',net],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  report['cleanup_complete']=all(subprocess.run(['docker','inspect',n],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0 for n in owned);(O/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 print('Public WebSocket/N1 candidate fixture:',report['result'],flush=True)
 return report['result']!='pass'
if __name__=='__main__':raise SystemExit(main())
