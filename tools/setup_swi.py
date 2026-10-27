#!/usr/bin/env python3
"""Prepare/check local pinned startup; never fetch, install or overwrite sources."""
from pathlib import Path
import argparse,hashlib,json,os,shlex,subprocess,sys
from pinned_swi import ROOT,validate,validate_payloads
DEFAULT=ROOT/'.trinity/native-swi.json'

def check(state_file):
    state=json.loads(state_file.read_text())
    native=Path(state['native_root']).resolve(strict=True)
    record=validate(native)
    if state['revision']!=record['revision']:raise ValueError('setup pin differs; rerun setup')
    if Path(state['asset_root']).resolve()!=ROOT:raise ValueError('setup belongs to another demonstrator; rerun setup')
    wasm=Path(state['wasm_root']).resolve(strict=True);validate_payloads(native,wasm)
    return dict(record,asset_root=str(ROOT),wasm_root=str(wasm))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--native-root',type=Path)
    p.add_argument('--state-file',type=Path,default=Path(os.environ.get('WP_NATIVE_STATE',str(DEFAULT))))
    p.add_argument('--validate',action='store_true')
    p.add_argument('--shell',action='store_true',help='validate and emit quoted test environment')
    a=p.parse_args()
    try:
        state_file=a.state_file.resolve()
        if a.shell:
            state=check(state_file)
            for key,field in [('TRINITY_PINNED_SWI_ROOT','native_root'),('WP_ASSET_ROOT','asset_root'),('WP_WASM_SOURCE_DIR','wasm_root')]:
                print(key+'='+shlex.quote(state[field]))
            return
        if a.validate:
            print(json.dumps(check(state_file)));return
        if not a.native_root:raise ValueError('--native-root is required for setup')
        native=a.native_root.resolve(strict=True);record=validate(native)
        names=['shared_db.pl','statechart_wasm.pl','statechart_wasm_exec.pl','statechart_wasm_model.pl','statechart_wasm_runtime.pl','sxml_schema.pl']
        digest=hashlib.sha256()
        digest.update(record['revision'].encode())
        for name in names:digest.update(((native if name=='sxml_schema.pl' else ROOT)/'prolog/web_prolog/wasm'/name).read_bytes())
        wasm=state_file.parent/('browser-prolog-'+digest.hexdigest()[:16])
        state_file.parent.mkdir(parents=True,exist_ok=True)
        if not wasm.exists():
            subprocess.run([sys.executable,str(ROOT/'tools/package_wasm_prolog.py'),'--native-root',str(native),'--browser-root',str(ROOT),'--output',str(wasm)],check=True,stdout=subprocess.DEVNULL)
        validate_payloads(native,wasm)
        state=dict(record,asset_root=str(ROOT),wasm_root=str(wasm))
        temp=state_file.with_name(state_file.name+'.tmp');temp.write_text(json.dumps(state,indent=2)+'\n');os.replace(temp,state_file)
        print(json.dumps(state,indent=2))
    except (OSError,ValueError,KeyError,subprocess.CalledProcessError) as e:
        p.exit(2,'native SWI setup: '+str(e)+'; run python3 tools/setup_swi.py --native-root /path/to/swi-prolog-node\n')

if __name__=='__main__':main()
