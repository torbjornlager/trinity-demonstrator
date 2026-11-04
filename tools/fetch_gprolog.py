#!/usr/bin/env python3
"""Fetch the exact GNU port/engine sources into new build directories."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess

PIN = Path(__file__).resolve().parents[1] / 'dependencies/gprolog-port.json'
REPOSITORIES = ('https://github.com/torbjornlager/gprolog-port.git',
                'https://github.com/didoudiaz/gprolog.git')


def load_pin(path=PIN):
    pin = json.loads(path.read_text())
    for record, repository in zip((pin, pin['engine']), REPOSITORIES):
        if record['repository'] != repository or not re.fullmatch(r'[0-9a-f]{40}', record['revision']):
            raise ValueError('GNU dependencies require known repositories and full commit pins')
    if not re.fullmatch(r'\d+\.\d+\.\d+', pin['engine']['version']):
        raise ValueError('GNU engine version must have three numeric components')
    return pin


def fetch(record, destination, env):
    if destination.exists() or destination.is_symlink():
        raise ValueError(f'destination must not exist: {destination}')
    destination.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(destination)], env=env, check=True)
    subprocess.run(['git', '-C', str(destination), 'fetch', '-q', '--no-tags', '--depth=1',
                    record['repository'], record['revision']], env=env, check=True)
    subprocess.run(['git', '-C', str(destination), 'checkout', '-q', '--detach', 'FETCH_HEAD'],
                   env=env, check=True)
    revision = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != record['revision']:
        raise ValueError('GNU source checkout differs from its pin')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port-destination', type=Path, required=True)
    parser.add_argument('--engine-destination', type=Path, required=True)
    parser.add_argument('--token-file', type=Path)
    args = parser.parse_args()
    pin = load_pin()
    for path in (args.port_destination, args.engine_destination):
        if path.exists() or path.is_symlink():
            parser.error(f'destination must not exist: {path}')
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    if args.token_file and args.token_file.is_file():
        token = args.token_file.read_text().strip()
        if token:
            index = int(env.get('GIT_CONFIG_COUNT', '0'))
            encoded = base64.b64encode(('x-access-token:' + token).encode()).decode()
            env.update(GIT_CONFIG_COUNT=str(index + 1))
            env[f'GIT_CONFIG_KEY_{index}'] = 'http.https://github.com/.extraheader'
            env[f'GIT_CONFIG_VALUE_{index}'] = 'AUTHORIZATION: basic ' + encoded
    fetch(pin, args.port_destination, env)
    fetch(pin['engine'], args.engine_destination, env)
    version = (args.engine_destination / 'VERSION').read_text().strip()
    if version != 'gprolog-' + pin['engine']['version']:
        raise ValueError('GNU engine source version differs from the manifest')
    print(json.dumps(pin, indent=2))


if __name__ == '__main__':
    main()
