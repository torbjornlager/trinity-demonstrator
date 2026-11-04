#!/usr/bin/env python3
"""Build a minimal read-only GNU worker filesystem from the trusted image ELF."""
from pathlib import Path
import re
import shutil
import subprocess

worker = Path('/app/isobase/query-worker')
root = Path('/app/n6/jail-template')
root.mkdir(parents=True)
shutil.copy2(worker, root / 'query-worker')
output = subprocess.check_output(['ldd', str(worker)], text=True)
if 'not found' in output:
    raise SystemExit('worker library dependency missing')
for path in re.findall(r'(?<!\S)(/[^\s]+)', output):
    source = Path(path)
    destination = root / source.relative_to('/')
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination, follow_symlinks=True)
for path in sorted(root.rglob('*'), reverse=True):
    path.chmod(0o555)
root.chmod(0o555)
