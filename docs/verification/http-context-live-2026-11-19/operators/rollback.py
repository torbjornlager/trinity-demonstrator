"""Guard explicit recovery against replacing a successor or newer host selection."""
import hashlib,json,subprocess,sys
from pathlib import Path
P=Path(__file__).resolve().parent;R=P.parents[1]
state=json.loads((P/'rollback-selected-state.json').read_text())
for name,digest in state['host_selection_hashes'].items():assert hashlib.sha256((R/name).read_bytes()).hexdigest()==digest,'Host selection moved; inspect before recovery'
for t in state['targets']:
 now=json.loads(subprocess.check_output(['docker','inspect',t['container']]))[0]
 assert now['Id']==t['id'] and now['Image']==t['image'],'Successor changed: '+t['container']
seal=json.loads((P/'seal.json').read_text())
for n,h in seal['files'].items():assert hashlib.sha256((P/n).read_bytes()).hexdigest()==h,'Sealed recovery input changed: '+n
print('Exact deployed services and host selections verified',flush=True)
if '--check' not in sys.argv:raise SystemExit(subprocess.call([sys.executable,str(P/'deploy.py'),'--rollback']))
