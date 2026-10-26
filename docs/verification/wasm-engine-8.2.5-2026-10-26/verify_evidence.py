#!/usr/bin/env python3
"""Check saved acceptance evidence without contacting or starting any node."""
import gzip,json,re
from pathlib import Path
HERE=Path(__file__).resolve().parent
load=lambda n:json.loads((HERE/n).read_text())
summary=load('summary.json');assert summary['wasm_tier']['exit_code']==0
log=(HERE/'WASM.log').read_text();assert len(re.findall(r'^  ok ',log,re.M))==2751;assert 'all scenarios passed' in log and '!!! Tier' not in log
assert load('isolated-diff.json')['changed_tracked_paths']==['web/swipl-bundle.js']
rows=load('ui-results.json');raw=json.loads(gzip.decompress((HERE/'ui-evidence.json.gz').read_bytes()));assert len(rows)==len(raw)==26
for mode in ['worker','main']:
 selected=[r for r in raw if r['mode']==mode];assert len(selected)==13
 assert {r['id'] for r in selected if not r['passed']}=={'e009'}
 for row in selected:
  s=row['state'].replace('\u00a0',' ');assert ('ACTOR (DOM)' if mode=='main' else 'ACTOR (WORKERS)') in s
  terminal=s[s.index('text Terminal'):s.index('text Logger')]
  assert row['passed']==bool(re.search(r'text Candidate = '+row['id']+r'(?=[.,\n])',terminal))
 for suffix,expected in [('failure','false.'),('error','Candidate_output_error')]:
  s=(HERE/(mode+'-output-'+suffix+'.ax.txt')).read_text().replace('\u00a0',' ');terminal=s[s.index('text Terminal'):s.index('text Logger')];last=terminal[terminal.rfind('text ?- write'):]
  assert last.index('text [a,b,c]')<last.index('text '+expected)
 old=(HERE/'old-control'/(mode+'-statechart.ax.txt')).read_text().replace('\u00a0',' ')
 assert 'text Missing_chart_down' in old and 'swi(10,1,8,[])' in old
for small,full in zip(rows,raw):assert small=={k:v for k,v in full.items() if k!='state'}
assert all(load('preservation.json')['checks'].values())
assert load('package.json')['version']=='8.2.5'
assert load('provenance.json')['package_integrity_verified']==load('package.json')['dist']['integrity']
for prefix in ['','old-control/']:assert load(prefix+'ui-node-stopped.json')['exit_code'] is not None
print('Verified: full tier passed; 12/13 UI assertions per mode; remaining statechart diagnostic also fails on old engine; output ordering and preservation pass.')
