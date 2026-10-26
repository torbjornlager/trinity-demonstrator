#!/usr/bin/env python3
"""Extra CI checks: clean export, fixed repetitions and injected pipeline errors."""
from pathlib import Path
import hashlib,io,json,os,shutil,subprocess,sys,tarfile,tempfile,time
OUT=Path(__file__).resolve().parent
RECORD=OUT.parent
ROOT=RECORD.parents[2]
node=Path(json.loads((RECORD/'node.json').read_text())['executable'])
swipl=Path.home()/'.local/share/trinity-runtime-tests/swipl-10.1.19-ci-2026-10-25/run-swipl'
script=(RECORD/'workflow-step.sh').read_text()
base=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
env=dict(os.environ,PATH=str(node.parent)+os.pathsep+os.environ['PATH'],SWIPL=str(swipl),WP_NATIVE_MODE='legacy',GITHUB_SHA=base)
env.pop('WP_EXPERIMENTAL_TEXT',None)
# Prevent accidental inheritance of external setup/source selection.
for key in ['WP_NATIVE_STATE','TRINITY_PINNED_SWI_ROOT','WP_ASSET_ROOT','WP_WASM_SOURCE_DIR','SWI_HOME_DIR','SWIPL_HOME_DIR']:
    env.pop(key,None)
rows=[r for r in json.loads((OUT/'results.json').read_text()) if not r['label'].startswith('pipeline-')] if '--negative-only' in sys.argv else []
def record(row):
    rows.append(row);(OUT/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print(row,flush=True)
def call(label,command,cwd=ROOT,extra=None,limit=400):
    start=time.monotonic()
    with (OUT/(label+'.log')).open('w') as log:
        p=subprocess.Popen(command,cwd=cwd,env=dict(env,**(extra or {})),stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try:code=p.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            import signal
            os.killpg(p.pid,signal.SIGKILL);p.wait();code=124
    return dict(label=label,exit_code=code,seconds=round(time.monotonic()-start,3))

if '--negative-only' not in sys.argv:
    with tempfile.TemporaryDirectory(prefix='wasm-clean-export-') as d:
        clean=Path(d)
        archive=subprocess.check_output(['git','archive','HEAD'],cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:tar.extractall(clean)
        for name in ['.github/workflows/ci.yml','README.md']:
            shutil.copy2(ROOT/name,clean/name)
        assert not (clean/'.trinity').exists() and not (clean/'.git').exists()
        record(dict(label='clean-inputs',base_commit=base,no_git_or_local_setup=True,private_checkout_absent=True,
                    contracts_sha256=hashlib.sha256((clean/'tests/wasm/swi_wasm_contracts.js').read_bytes()).hexdigest()))
        row=call('clean-export-wasm',['bash','-c',script],clean,dict(RUNNER_TEMP=str(OUT/'clean-artifacts')))
        record(row)
        assert row['exit_code']==0,'clean export failed; inspect log'

    # Repeat the new behavior-focused contracts in separate real-engine processes.
    for scenario in ['portable_text_worker','portable_text_main','compatibility_output_ordering']:
        totals=[]
        for n in range(10):
            row=call(scenario+'-'+str(n+1),[str(node),'tests/wasm/swi_wasm_contracts.js',scenario])
            log=(OUT/(row['label']+'.log')).read_text()
            row['ok_assertions']=sum(line.startswith('  ok ') for line in log.splitlines())
            assert row['exit_code']==0 and row['ok_assertions']>0,row
            totals.append(row)
        record(dict(label=scenario,repetitions=10,passed=10,ok_assertions=sum(r['ok_assertions'] for r in totals),seconds=round(sum(r['seconds'] for r in totals),3)))

# Use the exact job step with isolated fake tiers, never patching repository tests.
for kind,expected in [('timeout',124),('log-writer-error',9),('bad-engine',None)]:
    with tempfile.TemporaryDirectory(prefix='wasm-job-negative-') as d:
        d=Path(d);(d/'tools').mkdir();(d/'bin').mkdir()
        shutil.copy2(ROOT/'tools/ci_timeout.py',d/'tools/actual_timeout.py')
        if kind=='timeout':
            (d/'tools/ci_timeout.py').write_text('import sys\nfrom actual_timeout import run\nraise SystemExit(run(sys.argv[3:],0.3,grace=0.1))\n')
            (d/'tools/test.sh').write_text('echo before-timeout\nexec python3 -c "import time;time.sleep(30)"\n')
        else:
            shutil.copy2(ROOT/'tools/ci_timeout.py',d/'tools/ci_timeout.py')
            (d/'tools/test.sh').write_text('echo tier-ran\nexit 0\n')
        if kind=='log-writer-error':
            tee=d/'bin/tee';tee.write_text('#!/bin/sh\ncat > /dev/null\nexit 9\n');tee.chmod(0o755)
        custom=dict(RUNNER_TEMP=str(d),PATH=str(d/'bin')+os.pathsep+env['PATH'])
        if kind=='bad-engine':custom['SWIPL']=str(d/'missing-swipl')
        if kind=='bad-engine':
            baseline=subprocess.run(['bash','-c','set -euo pipefail; "$SWIPL" --version'],cwd=d,env=dict(env,**custom),text=True,capture_output=True)
            expected=baseline.returncode
            assert expected!=0 and 'missing-swipl' in baseline.stderr
        row=call('pipeline-'+kind,['bash','-c',script],d,custom,limit=15)
        assert row['exit_code']==expected,row
        row['expected_exit_code']=expected
        if kind=='bad-engine':
            row['no_language_tests_started']=not (d/'wasm-ci-results/WASM.log').exists()
            assert row['no_language_tests_started']
            assert 'missing-swipl' in (OUT/('pipeline-'+kind+'.log')).read_text()

        row['version_metadata_retained']=(d/'wasm-ci-results/versions.log').exists()
        assert row['version_metadata_retained']
        if kind=='timeout':
            row['partial_log_retained']='before-timeout' in (d/'wasm-ci-results/WASM.log').read_text()
            assert row['partial_log_retained']
        record(row)
print('All extended checks passed; disposable exports/fixtures removed.',flush=True)
