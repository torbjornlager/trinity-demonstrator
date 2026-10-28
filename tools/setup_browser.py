#!/usr/bin/env python3
"""Read CI checkout inputs, or install an exact browser package for this consumer."""
import argparse,json,re,sys
from pathlib import Path
from pinned_browser import PIN,install,check
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--github-outputs',type=Path);p.add_argument('--browser-root',type=Path);p.add_argument('--native-root',type=Path);p.add_argument('--validate',action='store_true');a=p.parse_args()
try:
    if a.github_outputs:
        pin=json.loads(PIN.read_text());m=re.fullmatch(r'https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\.git',pin['repository'])
        if not m or not re.fullmatch(r'[a-f0-9]{40}',pin['revision']):raise ValueError('browser pin must use a GitHub repository and exact SHA')
        with a.github_outputs.open('a') as output:output.write('repository='+m[1]+'\nrevision='+pin['revision']+'\n')
    elif a.validate:print(check()[0])
    else:print(install(a.browser_root,a.native_root))
except (OSError,ValueError,KeyError) as e:p.exit(2,'browser dependency: '+str(e)+'\n')
