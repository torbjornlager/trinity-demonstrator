#!/usr/bin/env python3
"""Build/start the isolated owner-only N6 localhost or HTTPS stack."""
import argparse
import os
from pathlib import Path
import subprocess
from setup_n6 import main as setup_credentials

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true', help='build exact pinned dependencies and UI assets first')
    parser.add_argument('--stop', action='store_true', help='stop the selected N6 stack without deleting images or credentials')
    parser.add_argument('--https', action='store_true', help='use the isolated owner-only n6.elfenbenstornet.se stack')
    args = parser.parse_args()
    setup_credentials()
    command = ['docker', 'compose', '--env-file', 'Deployment/.env.n6',
               '-f', 'Deployment/compose.gprolog-n6-local.yaml']
    if args.https:
        command += ['-f', 'Deployment/compose.gprolog-n6-host.yaml']
    services = ['n6_assets', 'wp_n6'] + (['n6_admission'] if args.https else ['n6_hub'])
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
        subprocess.run(command + ['build', 'n6_assets', 'wp_n6'] + (['n6_admission'] if args.https else []), cwd=ROOT, env=env, check=True)
    subprocess.run(command + ['up', '-d', '--no-build', '--wait'] + services,
                   cwd=ROOT, env=env, check=True)
    print('N6: ' + ('https://n6.elfenbenstornet.se' if args.https else 'http://localhost:3057') + '/demonstrator')
    if not args.https:
        print('Local Discovery Hub: http://localhost:3058/discovery-hub')
    print('Owner credentials: ' + str(ROOT / '.trinity/n6-access.txt'))


if __name__ == '__main__':
    main()
