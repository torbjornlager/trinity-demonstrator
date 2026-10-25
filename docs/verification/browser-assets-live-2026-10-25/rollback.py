#!/usr/bin/env python3
"""Restore the prior browser selection only; no process/engine changes."""
from pathlib import Path
import json,os,shutil,subprocess
HERE=Path(__file__).resolve().parent
record=json.loads((HERE/'update.json').read_text())
LIVE=Path(record['live_checkout']);STATE=LIVE.parent
current=json.loads((STATE/'selection.json').read_text())
previous=json.loads((HERE/'selection.json').read_text())
assert current['native']==previous['native'] and current['trealla']==previous['trealla'],'native selection has changed; review rollback manually'
assert current['demonstrator']['revision']==record['new_revision'],'another asset selection is active'
assert subprocess.check_output(['git','-C',str(LIVE),'rev-parse','HEAD'],text=True).strip()==record['new_revision']
subprocess.run(['git','-C',str(LIVE),'diff','--quiet','HEAD'],check=True)
old=Path(record['old_payload']);saved=Path(record['saved_payload'])
assert old.is_symlink() and old.resolve()==Path(record['new_payload']).resolve()
assert saved.is_dir()
subprocess.run(['git','-C',str(LIVE),'checkout','-q','--detach',record['old_revision']],check=True)
old.unlink();os.rename(saved,old)
for source,target in [(HERE/'native-swi.json',LIVE/'.trinity/native-swi.json'),(HERE/'selection.json',STATE/'selection.json')]:
    temp=target.with_name(target.name+'.rollback-tmp');shutil.copy2(source,temp);os.replace(temp,target)
subprocess.run(['python3',str(STATE/'verify.py')],check=True)
print('Previous browser assets restored. No node or engine restarted.')
