from pathlib import Path
import os,subprocess,json,shutil,tempfile
BASE=Path('/Users/torbjorn.lager/Documents/GitHub');ROOT=BASE/'trinity-demonstrator';NATIVE=BASE/'swi-prolog-node';OUT=Path(__file__).resolve().parent
EXE=Path.home()/'.local/share/trinity-runtimes/swi-current/bin/swipl'
# Tests exercise demonstrator assets/services with the explicit repaired native
# candidate. The copied test tree bypasses only the repository pin loader;
# production startup, repository pins and live nodes remain untouched.
with tempfile.TemporaryDirectory(prefix='model-jev-text-') as temp:
 root=Path(temp);shutil.copytree(ROOT/'tests',root/'tests');(root/'load.pl').write_text(":- ['"+str(NATIVE/'load.pl')+"'].\n:- set_setting(node_assets:root,'"+str(root)+"').\n")
 shutil.copytree(ROOT/'examples',root/'examples');(root/'prolog').symlink_to(NATIVE/'prolog');rows=[]
 for mode in ['default','chars']:
  env=dict(os.environ,WP_ASSET_ROOT=str(ROOT));env.pop('WP_EXPERIMENTAL_TEXT',None)
  if mode=='chars':env['WP_EXPERIMENTAL_TEXT']='portable-text-0.2'
  for suite,file,goal in ([('SERVICE_TEXT','service_text_tests.pl','run_tests([service_text,service_text_owner_options])')] if mode=='chars' else [('SERVICE_TEXT','service_text_tests.pl','run_tests([service_text,service_text_owner_options])'),('MODEL','model_service_tests.pl','run_tests(model_service)'),('MODEL_SXML','model_statechart_tests.pl','run_tests(model_statechart)'),('JEV','jev_tests.pl','run_tests(jev)')]):
   cmd=[str(EXE),'-f','none','-q','-s',str(root/'tests'/file),'-g',goal,'-t','halt']
   with (OUT/(mode+'-'+suite+'.log')).open('w') as log:
    try:code=subprocess.run(cmd,cwd=ROOT,env=env,stdout=log,stderr=log,timeout=100).returncode
    except subprocess.TimeoutExpired:code=124
   rows.append(dict(mode=mode,suite=suite,exit_code=code,command=cmd));print(mode,suite,code,flush=True)
 (OUT/'existing-checks.json').write_text(json.dumps(rows,indent=2)+'\n')
