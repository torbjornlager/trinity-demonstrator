#!/usr/bin/env python3
"""Audit saved repair evidence without contacting a running node."""
from pathlib import Path
import gzip,json,re,hashlib
HERE=Path(__file__).resolve().parent
load=lambda n:json.loads((HERE/n).read_text())
for log,result in [('WASM.log','wasm-results.json'),('WASM-frozen.log','frozen-results.json')]:
 text=(HERE/log).read_text();assert load(result)['exit_code']==0
 assert len(re.findall(r'^  ok ',text,re.M))==2780 and 'all scenarios passed' in text and '  FAIL ' not in text
batch=load('focused-batch.json');assert len(batch)==10 and all(r['exit_code']==0 for r in batch)
for prefix,total in [('',16),('live-',4)]:
 compact=load(prefix+'ui-results.json');raw=json.loads(gzip.decompress((HERE/(prefix+'ui-evidence.json.gz')).read_bytes()));assert len(raw)==len(compact)==total
 for small,full in zip(compact,raw):
  assert small=={k:v for k,v in full.items() if k!='state'} and full['passed']
  s=full['state'].replace('\u00a0',' ');assert ('ACTOR (DOM)' if full['mode']=='main' else 'ACTOR (WORKERS)') in s
  terminal=s[s.index('text Terminal'):s.index('text Logger')];assert re.search(r'text Check = '+full['id']+r'(?=[.,\n])',terminal)
assert all(load('preservation.json')['checks'].values())
assert all(load('update.json')['served_assets'].values())
assert load('ui/ui-node-stopped.json')['exit_code'] is not None
assert load('summary.json')['new_monitor_assertions']==29
print('Verified: 2,780 assertions in both full runs; 10 focused runs; 16 isolated and 4 live UI assertions; preservation checks pass.')
