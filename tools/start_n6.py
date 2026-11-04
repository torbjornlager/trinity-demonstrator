#!/usr/bin/env python3
"""Build/start the isolated owner-only localhost N6 stack."""
import argparse
import os
from pathlib import Path
import subprocess
from setup_n6 import main as setup_credentials

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true', help='build exact pinned dependencies and UI assets first')
    parser.add_argument('--stop', action='store_true', help='stop this local stack without deleting images or credentials')
    args = parser.parse_args()
    setup_credentials()
    command = ['docker', 'compose', '--env-file', 'Deployment/.env.n6',
               '-f', 'Deployment/compose.gprolog-n6-local.yaml']
    env = os.environ.copy()
    if args.stop:
        subprocess.run(command + ['stop'], cwd=ROOT, env=env, check=True)
        return
    if args.build:
        if not env.get('TRINITY_BUILD_TOKEN'):
            token = subprocess.run(['gh', 'auth', 'token'], capture_output=True, text=True, check=True).stdout.strip()
            if not token:
                raise SystemExit('Build needs a GitHub read token for the pinned source repositories')
            env['TRINITY_BUILD_TOKEN'] = token
        subprocess.run(command + ['build', 'n6_assets', 'wp_n6'], cwd=ROOT, env=env, check=True)
    subprocess.run(command + ['up', '-d', '--no-build', '--wait', 'n6_assets', 'wp_n6', 'n6_hub'],
                   cwd=ROOT, env=env, check=True)
    print('N6: http://localhost:3057/demonstrator')
    print('Local Discovery Hub: http://localhost:3058/discovery-hub')
    print('Owner credentials: ' + str(ROOT / '.trinity/n6-access.txt'))


if __name__ == '__main__':
    main()
