"""Validate job isolation and actual log-pipeline failure propagation."""
from pathlib import Path
import json,os,shutil,subprocess,tempfile
OUT=Path(__file__).resolve().parent
ROOT=OUT.parents[2]
def parse_yaml(text):
    return json.loads(subprocess.check_output(['ruby','-ryaml','-rjson','-e','puts JSON.generate(YAML.load(STDIN.read))'],input=text,text=True))
current=parse_yaml((ROOT/'.github/workflows/ci.yml').read_text())
base=parse_yaml(subprocess.check_output(['git','show','HEAD:.github/workflows/ci.yml'],cwd=ROOT,text=True))
assert {k:v for k,v in current.items() if k!='jobs'}=={k:v for k,v in base.items() if k!='jobs'}
for name in ['test','pinned-native']:assert current['jobs'][name]==base['jobs'][name],name
job=current['jobs']['wasm'];assert 'needs' not in job and 'if' not in job
assert job['env']=={'WP_NATIVE_MODE':'legacy'}
assert any(s.get('uses')=='actions/setup-node@v6' and s['with']['node-version']=='22' for s in job['steps'])
assert any(s.get('uses')=='./.github/actions/setup-swi' for s in job['steps'])
artifact=next(s for s in job['steps'] if s.get('uses')=='actions/upload-artifact@v4')
assert artifact['if']=='always()'
script=next(s['run'] for s in job['steps'] if s.get('name')=='Run existing WASM tier')
assert script.strip()==(OUT/'workflow-step.sh').read_text().strip()
for text in [script]+[s['run'] for s in current['jobs']['test']['steps'] if 'run' in s]:
    subprocess.run(['bash','-n'],input=text,text=True,check=True)
node=json.loads((OUT/'node.json').read_text())['executable']
swipl=Path.home()/'.local/share/trinity-runtime-tests/swipl-10.1.19-ci-2026-10-25/run-swipl'
rows=[]
for code in [0,7]:
    with tempfile.TemporaryDirectory() as d:
        d=Path(d);(d/'tools').mkdir()
        shutil.copy2(ROOT/'tools/ci_timeout.py',d/'tools/ci_timeout.py')
        (d/'tools/test.sh').write_text(f'echo fixture-output-{code}\nexit {code}\n')
        env=dict(os.environ,PATH=str(Path(node).parent)+os.pathsep+os.environ['PATH'],SWIPL=str(swipl),RUNNER_TEMP=str(d),GITHUB_SHA='pipeline-fixture')
        p=subprocess.run(['bash','-c',script],cwd=d,env=env,text=True,capture_output=True)
        assert p.returncode==code,(code,p.returncode,p.stderr)
        log=d/'wasm-ci-results/WASM.log'
        assert f'fixture-output-{code}' in log.read_text()
        versions=(d/'wasm-ci-results/versions.log').read_text()
        assert 'v22.' in versions and '10.1.19' in versions
        rows.append(dict(command_exit=code,job_step_exit=p.returncode,log_preserved=True,versions_recorded=True))
(OUT/'workflow-checks.json').write_text(json.dumps(dict(native_jobs_and_triggers_unchanged=True,wasm_job_independent=True,artifact_always=True,yaml_and_shell_syntax_valid=True,pipeline_cases=rows),indent=2)+'\n')
print('Workflow isolation and both pipeline cases passed')
