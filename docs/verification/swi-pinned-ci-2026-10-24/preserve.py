from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[3]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def snapshot():
 source={str(p.relative_to(ROOT)):digest(p) for p in (ROOT/'prolog').rglob('*') if p.is_file()}
 processes=subprocess.check_output(['ps','-axo','pid,lstart,command'],text=True)
 processes=[line for line in processes.splitlines() if ('start_local_node.pl' in line or 'n5_frontend.py' in line or ('tpl' in line and '306' in line)) and 'ps -axo' not in line]
 bins=[Path.home()/'.local/share/trinity-runtimes/swi-current/bin/swipl',ROOT.parent/'trealla-port/.build/trealla-current/tpl']
 return dict(native_copies=source,processes=processes,binaries={str(p):dict(target=str(p.resolve()),sha256=digest(p)) for p in bins if p.is_file()},native_revision=subprocess.check_output(['git','-C',str(ROOT.parent/'swi-prolog-node'),'rev-parse','HEAD'],text=True).strip(),native_status=subprocess.check_output(['git','-C',str(ROOT.parent/'swi-prolog-node'),'status','--porcelain'],text=True))
if __name__=='__main__':
 import sys
 Path(sys.argv[1]).write_text(json.dumps(snapshot(),indent=2)+'\n')
