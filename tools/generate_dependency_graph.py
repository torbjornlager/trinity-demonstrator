#!/usr/bin/env python3
"""Run the layering/graph tool owned by the validated native dependency."""
import os
from pathlib import Path
import subprocess
import sys
from setup_swi import check, DEFAULT

if __name__ == '__main__':
    state=check(Path(os.environ.get('WP_NATIVE_STATE', str(DEFAULT))))
    tool=Path(state['native_root'])/'tools/generate_dependency_graph.py'
    raise SystemExit(subprocess.call([sys.executable,str(tool),*sys.argv[1:]]))
