#!/usr/bin/env python3
"""Validate the exact port and engine sources used by the optional Trealla node."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / 'dependencies/trealla-port.json'
REPOSITORIES = {
    'port': 'https://github.com/torbjornlager/trealla-port.git',
    'engine': 'https://github.com/trealla-prolog/trealla.git',
}
REQUIRED_FILES = {
    'port': ['web_prolog.pl', 'Deployment/start_node.pl', 'Deployment/entrypoint.sh'],
    'engine': ['GNUmakefile', 'LICENSE'],
}


def load_pin(path=None):
    pin = json.loads((path or PIN).read_text())
    for kind, record in [('port', pin), ('engine', pin['engine'])]:
        if record['repository'] != REPOSITORIES[kind]:
            raise ValueError(f'unexpected Trealla {kind} repository')
        if not re.fullmatch(r'[0-9a-f]{40}', record['revision']):
            raise ValueError(f'Trealla {kind} pin must be a full commit SHA')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', pin['engine']['version']):
        raise ValueError('Trealla engine version must have three numeric components')
    return pin


def git(root, *arguments):
    return subprocess.check_output(
        ['git', '-C', str(root), *arguments], text=True, stderr=subprocess.PIPE
    ).strip()


def validate_checkout(root, record, kind):
    root = root.resolve(strict=True)
    if Path(git(root, 'rev-parse', '--show-toplevel')).resolve() != root:
        raise ValueError(f'Trealla {kind} root must be the checkout root')
    revision = git(root, 'rev-parse', 'HEAD')
    if revision != record['revision']:
        raise ValueError(f'Trealla {kind} revision differs from pin: {revision}')
    dirty = git(root, 'status', '--porcelain', '--untracked-files=all')
    if dirty:
        raise ValueError(f'Trealla {kind} sources differ from pinned commit: {dirty}')
    for relative in REQUIRED_FILES[kind]:
        file = root / relative
        if not file.is_file() or not file.resolve().is_relative_to(root):
            raise ValueError(f'missing or escaping Trealla {kind} source: {relative}')
    return revision


def validate_binary(binary, engine):
    binary = binary.resolve(strict=True)
    major, minor, patch = engine['version'].split('.')
    goal = (f'(current_prolog_flag(version_data,trealla({major},{minor},{patch},_))'
            '->halt(0);halt(1))')
    env = dict(os.environ, TPL_LIBRARY_PATH=str(binary.parent / 'library'))
    result = subprocess.run([str(binary), '-g', goal], env=env, timeout=30)
    if result.returncode:
        raise ValueError('Trealla binary version differs from pinned engine version')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port-root', type=Path)
    parser.add_argument('--engine-root', type=Path)
    parser.add_argument('--engine-binary', type=Path)
    args = parser.parse_args()
    try:
        pin = load_pin()
        if args.port_root:
            validate_checkout(args.port_root, pin, 'port')
        if args.engine_root:
            validate_checkout(args.engine_root, pin['engine'], 'engine')
        if args.engine_binary:
            validate_binary(args.engine_binary, pin['engine'])
        print(json.dumps(pin, indent=2))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(2, f'pinned Trealla dependency: {error}\n')


if __name__ == '__main__':
    main()
