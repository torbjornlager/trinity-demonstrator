#!/usr/bin/env python3
"""Fetch only the manifest-pinned Trealla sources into fresh directories."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess

from pinned_trealla import load_pin, validate_checkout


def fetch_environment(token_file=None):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    if token_file and token_file.is_file():
        token = token_file.read_text().strip()
        if token:
            encoded = base64.b64encode(('x-access-token:' + token).encode()).decode()
            index = int(env.get('GIT_CONFIG_COUNT', '0'))
            env.update({
                'GIT_CONFIG_COUNT': str(index + 1),
                f'GIT_CONFIG_KEY_{index}': 'http.https://github.com/.extraheader',
                f'GIT_CONFIG_VALUE_{index}': 'AUTHORIZATION: basic ' + encoded,
            })
    return env


def fetch(record, destination, kind, env):
    if destination.exists() or destination.is_symlink():
        raise ValueError(f'destination must not exist: {destination}')
    destination = destination.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    subprocess.run(['git', 'init', '--quiet', str(destination)], check=True, env=env)
    subprocess.run(['git', '-C', str(destination), 'fetch', '--quiet', '--no-tags',
                    '--depth=1', record['repository'], record['revision']],
                   check=True, env=env)
    subprocess.run(['git', '-C', str(destination), 'checkout', '--quiet',
                    '--detach', 'FETCH_HEAD'], check=True, env=env)
    validate_checkout(destination, record, kind)
    if kind == 'engine':
        # Version generation uses git describe. This local tag labels the
        # verified commit; no mutable upstream tag is fetched or trusted.
        subprocess.run(['git', '-C', str(destination), 'tag',
                        'v' + record['version'], record['revision']], check=True, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port-destination', type=Path)
    parser.add_argument('--engine-destination', type=Path)
    parser.add_argument('--token-file', type=Path)
    args = parser.parse_args()
    if not args.port_destination and not args.engine_destination:
        parser.error('a port or engine destination is required')
    try:
        pin = load_pin()
        destinations = [(args.port_destination, pin, 'port'),
                        (args.engine_destination, pin['engine'], 'engine')]
        # Refuse all existing destinations before creating either checkout.
        for destination, _, _ in destinations:
            if destination and (destination.exists() or destination.is_symlink()):
                raise ValueError(f'destination must not exist: {destination}')
        env = fetch_environment(args.token_file)
        for destination, record, kind in destinations:
            if destination:
                fetch(record, destination, kind, env)
        print(json.dumps(pin, indent=2))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(2, f'fetch Trealla: {error}\n')


if __name__ == '__main__':
    main()
