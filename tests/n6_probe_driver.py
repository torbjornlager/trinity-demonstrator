"""Runs in a disposable root launcher with precisely the production capabilities."""
import json,os,pathlib,secrets,subprocess,time,urllib.request
root=pathlib.Path('/tmp/probe');root.mkdir();(root/'leases').mkdir()
token=secrets.token_hex(32);f=root/'token';f.write_text(token);f.chmod(0o600)
r,w=os.pipe2(os.O_CLOEXEC)
p=subprocess.Popen(['/app/isobase/isobase-node','--port','8081','--auth-token-file',str(f),
 '--query-jail','/app/n6/jail-template','--lease-dir',str(root/'leases'),'--parent-fd',str(r),
 '--shared-db','/app/n6/shared_db.pl','--time-ms','2000'],pass_fds=(r,),stdout=subprocess.PIPE,text=True)
os.close(r)
assert json.loads(p.stdout.readline())['port']==8081

def workers():
    out=[]
    for proc in pathlib.Path('/proc').glob('[0-9]*'):
        try:
            if 20000<=proc.stat().st_uid<=60000:out.append(proc.name)
        except FileNotFoundError:pass
    return out

def call(goal):
    q=urllib.request.Request('http://127.0.0.1:8081/call?goal='+goal+'&format=json',headers={'Authorization':'Bearer '+token})
    with urllib.request.urlopen(q,timeout=5) as response: body=response.read().decode()
    assert 'checks_passed' in body,body

call('probe');time.sleep(.25);assert not workers(),workers()
call('lifetime');assert workers()
os.close(w);assert p.wait(timeout=5)==0
time.sleep(.25);assert not workers(),workers()
print('PASS native containment: credentials, chroot, caps, files, FDs, network, namespaces, ptrace, limits, fork bounds, orphan and presenter-death cleanup')
