#!/usr/bin/env python3
"""Execute the exact job shell step with separate Node/SWI test runtimes."""
from pathlib import Path
import json,os,subprocess,time
OUT=Path(__file__).resolve().parent
ROOT=OUT.parents[2]
node=json.loads((OUT/'node.json').read_text())['executable']
swipl=Path.home()/'.local/share/trinity-runtime-tests/swipl-10.1.19-ci-2026-10-25/run-swipl'
env=os.environ.copy()
env.update(PATH=str(Path(node).parent)+os.pathsep+env['PATH'],SWIPL=str(swipl),WP_NATIVE_MODE='legacy',RUNNER_TEMP=str(OUT),GITHUB_SHA=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip())
env.pop('WP_EXPERIMENTAL_TEXT',None)
start=time.monotonic()
with (OUT/'driver-stderr.log').open('w') as err:
    code=subprocess.call(['bash',str(OUT/'workflow-step.sh')],cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=err)
if (OUT/'driver-stderr.log').stat().st_size==0:(OUT/'driver-stderr.log').unlink()
row=dict(command=['bash','workflow-step.sh'],exit_code=code,seconds=round(time.monotonic()-start,3),node=node,swipl=str(swipl),base_commit=env['GITHUB_SHA'],platform='macOS arm64; hosted Ubuntu verification pending push')
(OUT/'run-results.json').write_text(json.dumps(row,indent=2)+'\n')
print(json.dumps(row),flush=True)
raise SystemExit(code)
