"""Hot-select committed browser assets; never restart a node or change engines."""
from pathlib import Path
from urllib.request import urlopen
import hashlib,json,os,shutil,subprocess
OUT=Path(__file__).resolve().parent
REPO=OUT.parents[2]
STATE=Path.home()/'.local/share/trinity-local-nodes/committed-adoption-2026-10-25'
ROLLBACK=STATE.parent/'browser-assets-rollback-2026-10-25'
LIVE=STATE/'demonstrator'
TARGET='b9ea7c557a61faf5ef9524fb97500bbe1ff89015'
def git(*args):return subprocess.check_output(['git',*args],text=True).strip()
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def fetch(path):
    with urlopen('http://localhost:3053/'+path,timeout=10) as response:return response.read()
selection=json.loads((STATE/'selection.json').read_text())
old=selection['demonstrator']['revision']
assert git('-C',str(LIVE),'rev-parse','HEAD')==old
subprocess.run(['python3',str(STATE/'verify.py')],check=True)
assert not ROLLBACK.exists(),'rollback directory already exists; inspect instead of overwriting'
changed=git('-C',str(REPO),'diff','--name-only',old,TARGET).splitlines()
assert all(p.startswith(('docs/','web/','tests/wasm/')) or p in ['README.md','DEVIATIONS.md','prolog/web_prolog/wasm/statechart_wasm_model.pl'] for p in changed),changed
ROLLBACK.mkdir()
for name in ['selection.json','engine-selection.json','verify.py','start_local_node.pl']:
    shutil.copy2(STATE/name,ROLLBACK/name)
shutil.copy2(LIVE/'.trinity/native-swi.json',ROLLBACK/'native-swi.json')
setup=json.loads((LIVE/'.trinity/native-swi.json').read_text())
old_payload=Path(setup['wasm_root'])
assert old_payload.is_dir() and not old_payload.is_symlink()
protected_files=[STATE.parent/'n3/start.sh',STATE.parent/'n5/start.sh',STATE.parent/'n5/frontend.py']
engines=json.loads((STATE/'engine-selection.json').read_text())
for p in engines:protected_files.append(Path(p))
before=dict(selection=selection,setup=setup,processes=subprocess.check_output(['ps','-p','13773,13791,91509,97669','-o','pid=,lstart=,command='],text=True),protected_sha256={str(p):digest(p) for p in protected_files},engine_selection=engines,n3_config_sha256=hashlib.sha256(fetch('admin/config')).hexdigest(),changed_paths=changed)
(OUT/'before.json').write_text(json.dumps(before,indent=2)+'\n')
# Prepare the exact six source payloads before touching the served paths.
names=['shared_db.pl','statechart_wasm.pl','statechart_wasm_exec.pl','statechart_wasm_model.pl','statechart_wasm_runtime.pl','sxml_schema.pl']
blobs={name:(Path(selection['native']['path'])/'prolog/web_prolog/wasm'/name).read_bytes() if name=='sxml_schema.pl' else subprocess.check_output(['git','-C',str(REPO),'show',TARGET+':prolog/web_prolog/wasm/'+name]) for name in names}
h=hashlib.sha256();h.update(selection['native']['revision'].encode())
for name in names:h.update(blobs[name])
new_payload=LIVE/'.trinity'/('browser-prolog-'+h.hexdigest()[:16])
assert not new_payload.exists(),new_payload
new_payload.mkdir()
manifest=[]
for name,body in blobs.items():
    (new_payload/name).write_bytes(body)
    source=(Path(selection['native']['path']) if name=='sxml_schema.pl' else LIVE)/'prolog/web_prolog/wasm'/name
    manifest.append(dict(path=name,source=str(source),sha256=hashlib.sha256(body).hexdigest()))
(new_payload/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
subprocess.run(['git','-C',str(LIVE),'fetch','-q',str(REPO),TARGET],check=True)
subprocess.run(['git','-C',str(LIVE),'update-ref','refs/rollback/browser-assets-2026-10-25',old],check=True)
record=dict(old_revision=old,new_revision=TARGET,live_checkout=str(LIVE),rollback=str(ROLLBACK),old_payload=str(old_payload),saved_payload=str(ROLLBACK/'browser-payload'),new_payload=str(new_payload))
(ROLLBACK/'update.json').write_text(json.dumps(record,indent=2)+'\n')
# Rollback is fully prepared before publication. New source checkout changes
# only browser/test/docs files; native implementation and examples are identical.
subprocess.run(['git','-C',str(LIVE),'checkout','-q','--detach',TARGET],check=True)
try:
    os.rename(old_payload,ROLLBACK/'browser-payload')
    old_payload.symlink_to(new_payload,target_is_directory=True)
    setup['wasm_root']=str(new_payload)
    tmp=LIVE/'.trinity/native-swi.json.tmp';tmp.write_text(json.dumps(setup,indent=2)+'\n');os.replace(tmp,LIVE/'.trinity/native-swi.json')
    selection['demonstrator']['revision']=TARGET
    tmp=STATE/'selection.json.tmp';tmp.write_text(json.dumps(selection,indent=2)+'\n');os.replace(tmp,STATE/'selection.json')
    subprocess.run(['python3',str(STATE/'verify.py')],check=True)
    subprocess.run(['python3',str(LIVE/'tools/setup_swi.py'),'--validate'],check=True,stdout=subprocess.DEVNULL)
    page=fetch('portal?node=swi-wasm')
    expected=subprocess.check_output(['git','-C',str(REPO),'show',TARGET+':web/demonstrator.html'])
    assert page==expected,'served portal is not the selected commit'
    assert fetch('swi_wasm_actor_worker.js')==subprocess.check_output(['git','-C',str(REPO),'show',TARGET+':web/swi_wasm_actor_worker.js'])
    for name in names:assert fetch('wasm/'+name)==blobs[name],name
    assert before['processes']==subprocess.check_output(['ps','-p','13773,13791,91509,97669','-o','pid=,lstart=,command='],text=True)
    assert all(digest(Path(p))==sha for p,sha in before['protected_sha256'].items())
    assert hashlib.sha256(fetch('admin/config')).hexdigest()==before['n3_config_sha256']
except Exception:
    if old_payload.is_symlink():old_payload.unlink()
    if (ROLLBACK/'browser-payload').exists():os.rename(ROLLBACK/'browser-payload',old_payload)
    subprocess.run(['git','-C',str(LIVE),'checkout','-q','--detach',old],check=True)
    shutil.copy2(ROLLBACK/'native-swi.json',LIVE/'.trinity/native-swi.json')
    shutil.copy2(ROLLBACK/'selection.json',STATE/'selection.json')
    raise
(OUT/'update.json').write_text(json.dumps(dict(record,all_processes_unchanged=True,protected_files_unchanged=True,n3_config_unchanged=True,exact_assets_and_six_payloads_verified=True),indent=2)+'\n')
print('Hot browser asset update passed: '+TARGET,flush=True)
