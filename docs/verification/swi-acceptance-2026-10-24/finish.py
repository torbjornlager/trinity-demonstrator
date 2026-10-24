from pathlib import Path
import os,subprocess,json,signal,time,hashlib
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[2];PREFIX=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/install'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
linkage=[]
for p in sorted(PREFIX.rglob('*')):
 if p.is_file()and not p.is_symlink()and(p.suffix in ['.so','.dylib']or p.parent==PREFIX/'bin'):
  r=subprocess.run(['otool','-L',str(p)],capture_output=True,text=True)
  if r.returncode==0:
   load=subprocess.check_output(['otool','-l',str(p)],text=True);lines=load.splitlines();rpaths=[]
   for i,line in enumerate(lines):
    if line.strip()=='cmd LC_RPATH':rpaths.append(lines[i+2].strip())
   linkage.append({'file':str(p.relative_to(PREFIX)),'dependencies':r.stdout,'rpaths':rpaths})
assert not any('/Applications/swipl' in r['dependencies']or '/Library/Frameworks/swipl' in r['dependencies']for r in linkage)
(OUT/'installed-linkage.json').write_text(json.dumps(linkage,indent=2)+'\n')
# Stop only the owned temporary node, after saving browser evidence.
pid=int((OUT/'ui-node.pid').read_text());command=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True)
assert str(PREFIX/'bin/swipl')in command and '51853'in command
os.kill(pid,signal.SIGTERM)
for _ in range(50):
 try:os.kill(pid,0)
 except ProcessLookupError:break
 time.sleep(.1)
else:os.killpg(pid,signal.SIGKILL)
before=json.loads((OUT/'before.json').read_text());current_processes=subprocess.check_output(['ps','-p','55051,42134,97896,97669','-o','pid=,command='],text=True)
checks={'protected_processes_unchanged':current_processes==before['live_processes'],'protected_binaries_unchanged':all(sha(Path(p))==v for p,v in before['binary_sha256'].items()),'runtime_and_test_sources_unchanged':all(sha(Path(p))==v for p,v in before['source_sha256'].items())}
assert all(checks.values())
(OUT/'final-preservation.json').write_text(json.dumps({'checks':checks,'live_processes':current_processes,'temporary_pid':pid,'temporary_node_stop_requested':True,'installed_prefix':str(PREFIX),'installed_macho_count':len(linkage)},indent=2)+'\n')
print(json.dumps(checks,indent=2))
