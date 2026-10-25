from pathlib import Path
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
