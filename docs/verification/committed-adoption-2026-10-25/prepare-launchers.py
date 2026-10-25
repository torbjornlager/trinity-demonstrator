from pathlib import Path
import json,hashlib,shutil
ROOT=Path.home()/'.local/share/trinity-local-nodes';STATE=ROOT/'committed-adoption-2026-10-25';selection=json.loads((STATE/'selection.json').read_text());BASE=Path('/Users/torbjorn.lager/Documents/GitHub')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
engines=[Path.home()/'.local/share/trinity-runtimes/swi-current/bin/swipl',BASE/'trealla-port/.build/trealla-current/tpl']
(STATE/'engine-selection.json').write_text(json.dumps({str(p):dict(target=str(p.resolve()),sha256=sha(p)) for p in engines},indent=2)+'\n')
verify='''from pathlib import Path
import json,subprocess,hashlib
ROOT=Path(__file__).resolve().parent
for name,item in json.loads((ROOT/'selection.json').read_text()).items():
    p=Path(item['path'])
    head=subprocess.check_output(['git','-C',str(p),'rev-parse','HEAD'],text=True).strip()
    if head!=item['revision']:raise SystemExit('Pinned checkout HEAD differs: '+name)
    if subprocess.call(['git','-C',str(p),'diff','--quiet','HEAD']):raise SystemExit('Pinned tracked files differ: '+name)
    others=subprocess.check_output(['git','-C',str(p),'ls-files','--others','--exclude-standard','--','prolog','load.pl','pack.pl','*.pl','examples','Deployment','web'],text=True)
    if others.strip():raise SystemExit('Untracked runtime/application inputs: '+name)
for path,item in json.loads((ROOT/'engine-selection.json').read_text()).items():
    p=Path(path)
    if str(p.resolve())!=item['target'] or hashlib.sha256(p.read_bytes()).hexdigest()!=item['sha256']:raise SystemExit('Selected engine changed: '+path)
'''
(STATE/'verify.py').write_text(verify)
oldpl=(ROOT/'portable-text-live-2026-10-25/start_local_node.pl').read_text()
oldpl=oldpl.replace(str(ROOT/'portable-text-live-2026-10-25/swi-source/load.pl'),str(STATE/'demonstrator/load.pl'))
oldpl=oldpl.replace(str(ROOT/'portable-text-live-2026-10-25/demonstrator'),str(STATE/'demonstrator'))
(STATE/'start_local_node.pl').write_text(oldpl)
wasm=json.loads((STATE/'demonstrator/.trinity/native-swi.json').read_text())['wasm_root']
script='#!/bin/sh\nset -eu\npython3 '+str(STATE/'verify.py')+'\ncd '+str(STATE/'demonstrator')+'\nunset SWI_HOME_DIR SWIPL_HOME_DIR WP_NATIVE_MODE WP_NATIVE_STATE\nexport WP_EXPERIMENTAL_TEXT=portable-text-0.2\nexport WP_ASSET_ROOT='+str(STATE/'demonstrator')+'\nexport WP_WASM_SOURCE_DIR='+wasm+'\nexec '+str(engines[0])+' -f none -q -s '+str(STATE/'start_local_node.pl')+' -- n3\n'
(STATE/'n3-start.sh').write_text(script);(STATE/'n3-start.sh').chmod(0o755)
script=(ROOT/'n5/start.sh').read_text();script='\n'.join('runtime=/Users/torbjorn.lager/Documents/GitHub/trealla-port/.build/trealla-current' if line.startswith('runtime=${TRINITY_TREALLA_RUNTIME:') else line for line in script.splitlines())+'\n';script='\n'.join('cd '+str(STATE/'trealla') if l.startswith('cd ') else l for l in script.splitlines())+'\n';script=script.replace('set -eu\n','set -eu\npython3 '+str(STATE/'verify.py')+'\n');(STATE/'n5-start.sh').write_text(script);(STATE/'n5-start.sh').chmod(0o755)
print('Commit-pinned launchers prepared; live launchers unchanged')
