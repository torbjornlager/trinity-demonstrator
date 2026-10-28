#!/usr/bin/env python3
"""Delegate the runtime algorithm guard to the pinned browser package."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
from pinned_browser import check as browser_check
from setup_swi import check, DEFAULT

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--native-root',type=Path)
    p.add_argument('--wasm-dir',type=Path)
    a=p.parse_args()
    package,_=browser_check()
    if a.native_root is None or a.wasm_dir is None:
        state=check(Path(os.environ.get('WP_NATIVE_STATE',str(DEFAULT))))
        a.native_root=a.native_root or Path(state['native_root'])
        a.wasm_dir=a.wasm_dir or Path(state['wasm_root'])
    raise SystemExit(subprocess.call([sys.executable,str(package/'tools/check_statechart_wasm_equivalence.py'),'--native-root',str(a.native_root),'--wasm-dir',str(a.wasm_dir)]))
