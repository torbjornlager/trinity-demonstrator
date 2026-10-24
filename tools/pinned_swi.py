#!/usr/bin/env python3
"""Run the demonstrator against its exact native dependency; no fetch or install.

This explicit wrapper shares validation with default startup. Browser payloads must have been
assembled with package_wasm_prolog.py into a separate fresh directory.
"""
from pathlib import Path
import argparse,json,os,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
PIN=ROOT/'dependencies/swi-prolog-node.json'

def git(root,*args):
    return subprocess.check_output(['git','-C',str(root),*args],text=True,stderr=subprocess.PIPE).strip()

def validate(native):
    pin=json.loads(PIN.read_text())
    revision=git(native,'rev-parse','HEAD')
    if revision!=pin['revision']:
        raise ValueError(f'native revision mismatch: expected {pin["revision"]}, got {revision}')
    dirty=git(native,'status','--porcelain','--untracked-files=all','--','prolog','load.pl','pack.pl')
    if dirty:
        raise ValueError('native runtime/package files differ from pinned revision: '+dirty)
    for rel in ['load.pl','pack.pl','prolog/web_prolog.pl','prolog/web_prolog/wasm/sxml_schema.pl']:
        path=native/rel
        if not path.is_file() or not path.resolve().is_relative_to(native):
            raise ValueError('missing or escaping native package file: '+rel)
    return dict(repository=pin['repository'],revision=revision,native_root=str(native),pack=pin['pack'])

def validate_payloads(native,wasm):
    names=['shared_db.pl','statechart_wasm.pl','statechart_wasm_exec.pl','statechart_wasm_model.pl','statechart_wasm_runtime.pl','sxml_schema.pl']
    for name in names:
        source=(native if name=='sxml_schema.pl' else ROOT)/'prolog/web_prolog/wasm'/name
        if (wasm/name).read_bytes()!=source.read_bytes():
            raise ValueError('assembled browser source differs from selected inputs: '+name)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--native-root',type=Path,required=True)
    p.add_argument('--swipl',type=Path)
    p.add_argument('--wasm-dir',type=Path)
    p.add_argument('--check',action='store_true',help='validate checkout and print pin without launching SWI')
    p.add_argument('arguments',nargs=argparse.REMAINDER)
    a=p.parse_args()
    try:
        native=a.native_root.resolve(strict=True);record=validate(native)
        if a.check:
            print(json.dumps(record,indent=2));return
        if not a.swipl or not a.swipl.is_file():raise ValueError('--swipl must name an existing verified executable')
        if not a.wasm_dir:raise ValueError('--wasm-dir must name an assembled browser payload directory')
        wasm=a.wasm_dir.resolve(strict=True)
        validate_payloads(native,wasm)
        env=dict(os.environ,TRINITY_PINNED_SWI_ROOT=str(native),WP_ASSET_ROOT=str(ROOT),WP_WASM_SOURCE_DIR=str(wasm))
        for key in ['SWI_HOME_DIR','SWIPL_HOME_DIR']:env.pop(key,None)
        args=a.arguments
        if args[:1]==['--']:args=args[1:]
        os.execve(str(a.swipl),[str(a.swipl),'-f','none','-s',str(ROOT/'tools/pinned_swi_bootstrap.pl'),*args],env)
    except (ValueError,OSError,subprocess.CalledProcessError) as e:
        p.exit(2,'pinned SWI dependency: '+str(e)+'\n')

if __name__=='__main__':main()
