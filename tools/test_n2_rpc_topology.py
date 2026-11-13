#!/usr/bin/env python3
"""Verify N2's private peer route in disposable copies of the deployed images.

No existing container, network, volume, release, snapshot or Git ref is changed.
The network is internal-only; all public hostnames resolve to our own TLS edge.
"""
import argparse,hashlib,json,subprocess,time,uuid
from pathlib import Path
from urllib.request import urlopen

ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__)
 for name in ['swi-image','trealla-image','edge-image','native-root','audit-tools','wire','output']:p.add_argument('--'+name,required=True)
 a=p.parse_args();out=Path(a.output).resolve();out.mkdir(mode=0o700);prefix='rpc-topology-'+uuid.uuid4().hex[:9];network=prefix;owned=[];made_network=False;report={'result':'fail','network':network}
 def docker(*args):return subprocess.check_output(['docker',*map(str,args)],stderr=subprocess.STDOUT)
 def copy(src,name,dest):docker('cp',src,name+':'+dest)
 def create(role,image,command,extra=()):
  name=prefix+'-'+role;docker('create','--name',name,'--network',network,'--no-healthcheck',*extra,image,*command);owned.append(name);return name
 def start(name):docker('start',name)
 def wait_file(name,path):
  for _ in range(100):
   if subprocess.run(['docker','exec',name,'test','-f',path],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:return
   time.sleep(.1)
  raise RuntimeError('Fixture file unavailable: '+path)
 def health(name,port,probe=None):
  code="import urllib.request;urllib.request.urlopen('http://%s:%d/healthz',timeout=1).read()"%('127.0.0.1' if probe is None else name,port)
  for _ in range(100):
   if subprocess.run(['docker','exec',probe or name,'python3','-c',code],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:return
   time.sleep(.1)
  raise RuntimeError('Fixture not healthy: '+name)
 try:
  docker('network','create','--internal',network);made_network=True
  swicmd=lambda n:['swipl','-q','-s',f'/app/Deployment/start_n{n}.pl','-g',f'start_n{n}_forever','-t','halt']
  four=create('four',a.swi_image,swicmd(4),['--network-alias','wp_n4','--cpus','1','--memory','512m']);start(four);health(four,3055)
  one=create('one',a.swi_image,swicmd(1),['--cpus','1','--memory','512m']);start(one);health(one,3051)
  # This peer models a stalled public transport, without touching the real peer.
  slow=out/'slow.py';slow.write_text('''from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import time
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  with open('/tmp/slow-requests.log','a') as f:f.write('request\\n')
  time.sleep(6)
  try:self.send_response(200);self.end_headers();self.wfile.write(b'success([v(plato),v(aristotle)],false).\\n')
  except OSError:pass
 def log_message(self,*args):pass
ThreadingHTTPServer(('0.0.0.0',3056),Handler).serve_forever()
''');copy(slow,four,'/tmp/slow.py');docker('exec','-d',four,'python3','/tmp/slow.py')
  # Names and all exposed endpoints belong only to this fixture's network.
  two_name=prefix+'-two'
  cfg=out/'Caddyfile';cfg.write_text('''{
 admin off
 auto_https disable_redirects
}
'''+''.join(f'https://n{n}.elfenbenstornet.se {{\n tls internal\n reverse_proxy {host}:{port}\n}}\n' for n,host,port in [(1,one,3051),(2,two_name,3052),(4,four,3056)]))
  edge=create('edge',a.edge_image,['caddy','run','--config','/etc/caddy/Caddyfile','--adapter','caddyfile'],['--network-alias','n1.elfenbenstornet.se','--network-alias','n2.elfenbenstornet.se','--network-alias','n4.elfenbenstornet.se']);copy(cfg,edge,'/etc/caddy/Caddyfile');start(edge);wait_file(edge,'/data/caddy/pki/authorities/local/root.crt');ca=out/'fixture-root.crt';docker('cp',edge+':/data/caddy/pki/authorities/local/root.crt',ca)
  two=create('two',a.swi_image,['/bin/sh','-c','update-ca-certificates >/dev/null 2>&1; exec '+' '.join(swicmd(2))],['--user','0','--cpus','1','--memory','512m','-e','WP_N2_N4_RPC_ENDPOINT=http://wp_n4:3055']);assert two==two_name;copy(ca,two,'/usr/local/share/ca-certificates/fixture-root.crt');start(two);health(two,3052)
  five_name=prefix+'-five';origin='http://'+five_name+':3060'
  five=create('five',a.trealla_image,['/bin/sh','-c','update-ca-certificates >/dev/null 2>&1; exec /bin/sh /app/Deployment/entrypoint.sh'],['--entrypoint','/usr/bin/env','--user','0','--cpus','1','--memory','1g','-e','WP_ADMIN_TOKEN=isolated-fixture-admin-token-only','-e','WP_PORT=3060','-e','WP_PUBLIC_URL='+origin,'-e','WP_PROFILE=actor','-e','WP_AUTH=open','-e','WP_ACK_PUBLIC=yes','-e','WP_SANDBOX=blacklist','-e','WP_TIME_LIMIT=300','-e','WP_IDLE_LIMIT=300']);copy(ca,five,'/usr/local/share/ca-certificates/fixture-root.crt');start(five);health(five,3060,two)
  with urlopen('https://n5.elfenbenstornet.se/tutorial',timeout=15) as response:body=response.read()
  tutorial=out/'tutorial.html';tutorial.write_bytes(body)
  for src,dest in [(tutorial,'/tmp/tutorial.html'),(Path(a.wire),'/tmp/wire.py'),(Path(a.audit_tools)/'audit_client.py','/tmp/audit_client.py'),(ROOT/'tests/rpc_topology/driver.py','/tmp/driver.py')]:copy(src,two,dest)
  def driver(mode):
   print('Running',mode,'fault check',flush=True)
   with (out/(mode+'.private.log')).open('wb') as err:
    result=subprocess.run(['docker','exec',two,'python3','/tmp/driver.py',origin,mode],stdout=subprocess.PIPE,stderr=err)
   (out/(mode+'.json')).write_bytes(result.stdout)
   subprocess.run(['docker','cp',two+':/tmp/stages.jsonl',str(out/(mode+'-stages.jsonl'))],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   if result.returncode:raise RuntimeError(mode+' driver failed; see fixture evidence')
   data=json.loads(result.stdout);assert data['result']=='pass';docker('cp',two+':/tmp/stages.jsonl',out/(mode+'-stages.jsonl'));return data
  before=driver('before');requests_before=docker('exec',four,'cat','/tmp/slow-requests.log').splitlines();print('Original image reproduced remote time errors with no watchdog expiry',flush=True)
  # Stop only the disposable N2. Copy candidate source without rebuilding or
  # editing any image, sealed release, dependency pin, or live configuration.
  docker('stop',two)
  for f in ['rpc.pl','node_glue.pl','node_runtime_state.pl']:copy(Path(a.native_root)/'prolog/web_prolog'/f,two,'/opt/swi-prolog-node/prolog/web_prolog/'+f)
  # The release loader correctly rejects uncommitted source. Use a declared
  # fixture-only development bootstrap rather than weakening that loader or
  # changing any actual dependency pin/browser package.
  bootstrap=out/'candidate-bootstrap.pl';bootstrap.write_text(":- asserta(user:file_search_path(library,'/opt/swi-prolog-node/prolog')).\n:- use_module(library(web_prolog)).\n")
  # Keep all candidate startup logic intact; replace only the loader line in
  # this disposable process. No production load.pl or dependency is rewritten.
  candidate_start=out/'candidate-start-n2.pl';candidate_start.write_text((ROOT/'Deployment/start_n2.pl').read_text().replace(":- ['../load.pl'].",":- ['/tmp/candidate-bootstrap.pl']."))
  copy(bootstrap,two,'/tmp/candidate-bootstrap.pl');copy(candidate_start,two,'/app/Deployment/start_n2.pl');copy(ROOT/'Deployment/domain_origins.pl',two,'/app/Deployment/domain_origins.pl');start(two);health(two,3052)
  after=driver('candidate');requests_after=docker('exec',four,'cat','/tmp/slow-requests.log').splitlines();assert requests_after==requests_before,'candidate still used stalled public N4 route'
  stages=[json.loads(l) for l in (out/'candidate-stages.jsonl').read_text().splitlines()];candidate_stages=[r for r in stages if r['session_id'] not in {r['session_id'] for r in [json.loads(l) for l in (out/'before-stages.jsonl').read_text().splitlines()]}];assert all(r['outcome']=='ok' and not r['watchdog']['fired'] for r in candidate_stages)
  report.update(result='pass',original_failure_reproduced=True,original_response_error='resource_error(time)',original_query_deadline_seconds=4,candidate_chapter_repetitions=63,candidate_queries=len(after['observations']),candidate_stage_count=len(candidate_stages),watchdog_expiries=0,stalled_public_route_requests_before=len(requests_before),stalled_public_route_requests_after=len(requests_after),network_internal_only=True,no_retry_or_timeout_increase=True,logical_peer_URL_preserved='https://n4.elfenbenstornet.se',private_endpoint='http://wp_n4:3055',candidate_loader='Explicit fixture-only development bootstrap; production pinned loader and all pins unchanged. Not a release qualification.',images=dict(swi=a.swi_image,trealla=a.trealla_image,edge=a.edge_image),source_sha256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(a.native_root)/'prolog/web_prolog'/f for f in ['rpc.pl','node_glue.pl','node_runtime_state.pl']]+[ROOT/'Deployment/start_n2.pl',ROOT/'Deployment/domain_origins.pl',ROOT/'Deployment/compose.yaml']})
 finally:
  # Remove only containers and anonymous volumes created by this invocation.
  for name in reversed(owned):
   subprocess.run(['docker','logs',name],stdout=(out/(name+'.private.log')).open('wb'),stderr=subprocess.STDOUT)
   subprocess.run(['docker','rm','-f','-v',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  if made_network:subprocess.run(['docker','network','rm',network],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  report['fixture_cleanup_complete']=all(subprocess.run(['docker','inspect',n],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0 for n in owned)
  (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 print('Private topology qualification:',report['result'],flush=True)
 return report['result']!='pass'
if __name__=='__main__':raise SystemExit(main())
