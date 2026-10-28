#!/usr/bin/env python3
"""Exact packaged browser dependency; the checkout is a build input, not runtime state."""
from pathlib import Path
import hashlib,json,os,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
PIN=ROOT/'dependencies/swi-wasm-node.json'
BASE=ROOT/'.trinity/browser-runtime'

def git(root,*args):return subprocess.check_output(['git','-C',str(root),*args],text=True,stderr=subprocess.PIPE).strip()
def validate_package(directory):
    pin=json.loads(PIN.read_text());raw=(directory/'manifest.json').read_bytes()
    if hashlib.sha256(raw).hexdigest()!=pin['manifest_sha256']:raise ValueError('browser package manifest differs from dependency pin')
    m=json.loads(raw)
    if m['source']['revision']!=pin['revision'] or m['source']['dirty']:raise ValueError('browser source revision differs or package is developmental')
    if {p.relative_to(directory).as_posix() for p in directory.rglob('*') if p.is_file()}!=set(m['files'])|{'manifest.json'}:raise ValueError('browser package file inventory differs')
    for rel,digest in m['files'].items():
        path=directory/rel
        if Path(rel).is_absolute() or '..' in Path(rel).parts or path.is_symlink() or not path.resolve().is_relative_to(directory.resolve()):raise ValueError('escaping browser package path')
        if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:raise ValueError('browser runtime/package files differ: '+rel)
    return m

def aliases(include_tests=True):
    rows={
        'dependencies/swi-wasm.json':'dependencies/swi-wasm.json',
        'web/swi_wasm_actor_worker.js':'web/swi_wasm_actor_worker.js',
        'web/swipl-bundle.js':'web/swipl-bundle.js',
        'web/vendor/swi-wasm-node.js':'web/vendor/swi-wasm-node.js',
        'web/vendor/swi-wasm-minimal.html':'web/vendor/swi-wasm-minimal.html'}
    if include_tests:
        for name in ['swi_wasm_actor_worker_smoke.js','swi_wasm_standalone.js']:rows['tests/wasm/'+name]='tests/wasm/'+name
    for name in ['statechart_wasm.pl','statechart_wasm_exec.pl','statechart_wasm_model.pl','statechart_wasm_runtime.pl']:rows['prolog/web_prolog/wasm/'+name]='web/wasm/'+name
    return rows

def check():
    pin=json.loads(PIN.read_text());directory=BASE/pin['revision'];m=validate_package(directory)
    current=BASE/'current'
    if not current.is_symlink() or current.resolve()!=directory.resolve():raise ValueError('selected browser package differs from dependency pin; rerun setup')
    for source,target in aliases((ROOT/'tests').is_dir()).items():
        link=ROOT/source
        if not link.is_symlink() or link.resolve()!=(directory/target).resolve():raise ValueError('browser asset alias differs: '+source)
    return directory,m

def install(source=None,native=None):
    pin=json.loads(PIN.read_text());directory=BASE/pin['revision']
    if source:
        source=source.resolve(strict=True)
        if git(source,'rev-parse','HEAD')!=pin['revision'] or git(source,'status','--porcelain','--untracked-files=all'):raise ValueError('browser checkout differs from exact clean dependency pin')
    if not directory.exists():
        source=source or Path(os.environ.get('SWI_WASM_SOURCE_ROOT',str(ROOT/'.trinity/swi-wasm-node'))).resolve(strict=True)
        if git(source,'rev-parse','HEAD')!=pin['revision'] or git(source,'status','--porcelain','--untracked-files=all'):raise ValueError('browser checkout differs from exact clean dependency pin')
        directory.parent.mkdir(parents=True,exist_ok=True)
        cmd=[sys.executable,str(source/'tools/package_runtime.py'),'--output',str(directory)]
        if native:cmd+=['--native-root',str(native)]
        subprocess.run(cmd,check=True,stdout=subprocess.PIPE)
    validate_package(directory)
    current=BASE/'current';temporary=BASE/'current.tmp'
    if temporary.is_symlink():temporary.unlink()
    temporary.symlink_to(directory.name,target_is_directory=True);os.replace(temporary,current)
    # Aliases are portable tracked links, not implementation copies. They keep
    # existing server URLs and test entry points working without native changes.
    for source,target in aliases((ROOT/'tests').is_dir()).items():
        link=ROOT/source;expected=os.path.relpath(BASE/'current'/target,link.parent)
        if not link.is_symlink() or os.readlink(link)!=expected:raise ValueError('tracked browser alias is missing or changed: '+source)
    return check()[0]
