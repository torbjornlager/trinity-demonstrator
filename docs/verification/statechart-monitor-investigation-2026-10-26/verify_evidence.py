#!/usr/bin/env python3
"""Verify the saved diagnostic observations without starting a runtime."""
from pathlib import Path
import gzip,json,re
HERE=Path(__file__).resolve().parent
rows=json.loads(gzip.decompress((HERE/'ui-evidence.json.gz').read_bytes()))
compact=json.loads((HERE/'probes.json').read_text());assert len(rows)==len(compact)==6
expected={'worker_mismatch','worker_explicit','main_early_liveness','main_spawn_monitor_ignored','main_chart_live','main_stop_no_notify'}
assert {r['id'] for r in rows}==expected
for full,short in zip(rows,compact):
 assert short=={k:v for k,v in full.items() if k!='state'}
 s=full['state'].replace('\u00a0',' ');assert ('ACTOR (DOM)' if full['mode']=='main' else 'ACTOR (WORKERS)') in s
 terminal=s[s.index('text Terminal'):s.index('text Logger')]
 assert re.search(r'text Probe = '+full['id']+r'(?=[.,\n])',terminal)
assert all(json.loads((HERE/'preservation.json').read_text())['checks'].values())
assert json.loads((HERE/'ui-node-stopped.json').read_text())['exit_code'] is not None
print('Six bounded diagnostic observations confirmed; adapter sources unchanged; disposable fixture stopped.')
