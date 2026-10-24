from pathlib import Path
import json,os,sys
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'tools'))
from ci_pinned_swi import run_checks
out=Path(__file__).resolve().parent/'legacy';out.mkdir(exist_ok=False)
exe=Path.home()/'.local/share/trinity-runtime-tests/swi-default-startup-2026-10-24/runtime/bin/swipl'
env=dict(os.environ,WP_NATIVE_MODE='legacy',SWIPL=str(exe))
rows=[(tier,ROOT,['bash','tools/test.sh',tier]) for tier in ['LINT','T0','T1','T2','T3','T4','T5']]
raise SystemExit(run_checks(rows,env,out))
