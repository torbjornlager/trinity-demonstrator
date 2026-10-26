#!/usr/bin/env python3
"""Restore only the prior served browser assets; no native restart or change."""
from pathlib import Path
import json,subprocess,os
HERE=Path(__file__).resolve().parent
selected=Path.home()/'.local/share/trinity-local-nodes/committed-adoption-2026-10-25'
old=json.loads((HERE/'selection.json').read_text());current=json.loads((selected/'selection.json').read_text())
expected=json.loads((HERE/'update.json').read_text())['new_revision']
if current['demonstrator']['revision']!=expected:raise SystemExit('Refusing rollback: another browser update is active')
for name in ['native','trealla']:
 if current[name]!=old[name]:raise SystemExit('Refusing rollback: native selection differs')
subprocess.run(['git','-C',current['demonstrator']['path'],'checkout','--detach',old['demonstrator']['revision']],check=True)
tmp=selected/'selection.rollback.json';tmp.write_text(json.dumps(old,indent=2)+'\n');os.replace(tmp,selected/'selection.json');subprocess.run(['python3',str(selected/'verify.py')],check=True)
print('Prior browser bundle restored; refresh browser pages. No node restarted.')
