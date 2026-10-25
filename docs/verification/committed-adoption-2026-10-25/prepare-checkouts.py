from pathlib import Path
import subprocess,json,shutil,hashlib
BASE=Path('/Users/torbjorn.lager/Documents/GitHub');STATE=Path.home()/'.local/share/trinity-local-nodes/committed-adoption-2026-10-25';STATE.mkdir();rows={};PINNED=json.loads((Path(__file__).resolve().parent/'selected-code.json').read_text())
for name,repo in [('native','swi-prolog-node'),('trealla','trealla-port'),('demonstrator','trinity-demonstrator')]:
 src=BASE/repo;rev=PINNED[name]['revision'];dest=STATE/name
 subprocess.run(['git','clone','-q','--no-hardlinks',str(src),str(dest)],check=True);subprocess.run(['git','-C',str(dest),'checkout','-q','--detach',rev],check=True)
 assert not subprocess.check_output(['git','-C',str(dest),'status','--porcelain'],text=True)
 rows[name]=dict(repository=repo,revision=rev,path=str(dest))
for name in ['n3','n5']:shutil.copy2(STATE.parent/name/'start.sh',STATE/(name+'-rollback.sh'))
(STATE/'selection.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows,indent=2))
