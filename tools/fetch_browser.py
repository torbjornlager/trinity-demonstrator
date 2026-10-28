#!/usr/bin/env python3
"""Fetch the manifest-pinned browser checkout for a container build."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
from pinned_browser import PIN, git

def validate(root):
    pin=json.loads(PIN.read_text())
    if git(root,'rev-parse','HEAD')!=pin['revision'] or git(root,'status','--porcelain','--untracked-files=all'):raise ValueError('browser checkout differs from dependency pin')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--destination',type=Path,required=True)
    p.add_argument('--token-file',type=Path)
    a=p.parse_args()
    destination=a.destination.resolve()
    if destination.exists():p.error('destination must not exist')
    pin=json.loads(PIN.read_text())
    env=dict(os.environ,GIT_TERMINAL_PROMPT='0')
    # Optional BuildKit secret stays out of command arguments, image layers,
    # repository remotes and persisted Git configuration.
    if a.token_file and a.token_file.is_file():
        token=a.token_file.read_text().strip()
        if token:
            encoded=base64.b64encode(('x-access-token:'+token).encode()).decode()
            env.update(GIT_CONFIG_COUNT='1',GIT_CONFIG_KEY_0='http.https://github.com/.extraheader',
                       GIT_CONFIG_VALUE_0='AUTHORIZATION: basic '+encoded)
    subprocess.run(['git','init','--quiet',str(destination)],check=True,env=env)
    subprocess.run(['git','-C',str(destination),'fetch','--quiet','--depth=1',pin['repository'],pin['revision']],check=True,env=env)
    subprocess.run(['git','-C',str(destination),'checkout','--quiet','--detach','FETCH_HEAD'],check=True,env=env)
    validate(destination)

if __name__=='__main__':main()
