#!/usr/bin/env python3
"""Check owner-authenticated SWI/Trealla → GNU calls in disposable containers.

Credentials travel only over stdin and to the fixed N6 adapter, never into the
live public node containers, command-line arguments, or printed diagnostics.
"""
import argparse
import base64
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swi-image', default='trinity-n6-assets:latest')
    parser.add_argument('--trealla-image', default='deployment-wp_n5:latest')
    args = parser.parse_args()
    text = (ROOT / '.trinity/n6-access.txt').read_text()
    password = next(line[10:] for line in text.splitlines() if line.startswith('Password: '))
    password_atom = "'" + password.replace("'", "''") + "'"
    goal = ("rpc('http://wp_n6:3060',human(X),"
            "[authorization(basic(owner," + password_atom + ")),limit(1)]),X=socrates")
    cases = [
        ('SWI', args.swi_image, 'swipl', ['-q', '-s', '/app/load.pl', '-g',
         'read_term(user_input,Goal,[]),catch((call(Goal)->Code=0;Code=1),E,(write_canonical(E),nl,Code=2)),system:halt(Code)']),
        ('Trealla', args.trealla_image, '/opt/trealla/tpl', ['-g',
         "use_module('/app/rpc.pl'),read(Goal),catch((call(Goal)->Code=0;Code=1),E,(writeq(E),nl,Code=2)),halt(Code)"])
    ]
    for name, image, entrypoint, arguments in cases:
        result = subprocess.run(['docker', 'run', '--rm', '-i', '--network', 'trinity-n6-local_default',
                                 '--entrypoint', entrypoint, image, *arguments],
                                input='(' + goal + ').\n', text=True, capture_output=True, timeout=60)
        if result.returncode:
            diagnostic = (result.stdout + result.stderr).replace(password, '<redacted>')
            diagnostic = diagnostic.replace(base64.b64encode(('owner:' + password).encode()).decode(), '<redacted>')
            raise SystemExit(f'{name} → GNU failed ({result.returncode}): ' + diagnostic[:2000])
        print(f'{name} → GNU authenticated RPC and first answer: passed')


if __name__ == '__main__':
    main()
