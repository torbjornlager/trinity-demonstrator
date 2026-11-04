#!/usr/bin/env python3
"""Replace the worker ONLY in a disposable image and exercise the real Linux jail."""
import argparse,pathlib,subprocess,tempfile,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--image',required=True);p.add_argument('--compiler-container');a=p.parse_args()
def run(*args,**kwargs):return subprocess.run(['docker',*args],check=True,**kwargs)
name='n6-probe-'+uuid.uuid4().hex[:12];compiler=a.compiler_container or name+'-compiler'
try:
    if not a.compiler_container:run('run','-d','--name',compiler,'gcc:14','sleep','600',stdout=subprocess.DEVNULL)
    run('cp',str(ROOT/'tests/n6_native_probe.c'),compiler+':/tmp/probe.c')
    run('exec',compiler,'cc','-Wall','-Wextra','-Werror','-O2','/tmp/probe.c','-o','/tmp/probe')
    with tempfile.TemporaryDirectory() as d:
        directory=pathlib.Path(d)
        run('cp',compiler+':/tmp/probe',str(directory/'probe'))
        (directory/'driver.py').write_bytes((ROOT/'tests/n6_probe_driver.py').read_bytes())
        (directory/'Dockerfile').write_text('FROM '+a.image+'\nCOPY --chmod=0555 probe /app/n6/jail-template/query-worker\nCOPY driver.py /app/probe_driver.py\nENTRYPOINT ["python3","/app/probe_driver.py"]\n')
        run('build','-q','-t',name,d,stdout=subprocess.DEVNULL)
        run('run','--rm','--user','0:0','--read-only','--tmpfs','/tmp:size=128m,mode=1777','--cap-drop','ALL',
            '--cap-add','KILL','--cap-add','SETGID','--cap-add','SETUID','--cap-add','SYS_CHROOT',
            '--security-opt','no-new-privileges:true','--pids-limit','384','--memory','1g','--cpus','.75',name)
finally:
    subprocess.run(['docker','image','rm',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if not a.compiler_container:subprocess.run(['docker','rm','-f',compiler],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
