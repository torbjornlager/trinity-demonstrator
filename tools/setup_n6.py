#!/usr/bin/env python3
"""Create local N6 owner credentials once, without printing passwords."""
import hashlib
from pathlib import Path
import secrets

ROOT = Path(__file__).resolve().parents[1]


def main():
    environment = ROOT / 'Deployment/.env.n6'
    access = ROOT / '.trinity/n6-access.txt'
    if environment.exists() or access.exists():
        if not environment.is_file() or not access.is_file():
            raise SystemExit('Incomplete N6 credential setup; existing files were preserved.')
        print(f'Existing N6 credentials preserved: {access}')
        return
    password = secrets.token_urlsafe(24)
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 200000).hex()
    encoded = f'pbkdf2_sha256:200000:{salt.hex()}:{digest}'
    access.parent.mkdir(exist_ok=True)
    with environment.open('x') as file:
        environment.chmod(0o600)
        file.write(f'N6_OWNER_PASSWORD_HASH={encoded}\n')
    with access.open('x') as file:
        access.chmod(0o600)
        file.write('Trinity N6 local preview\n\nURL: http://localhost:3057/demonstrator\n'
                   f'Username: owner\nPassword: {password}\n\n'
                   'Local Discovery Hub: http://localhost:3058/discovery-hub\n'
                   'These credentials authorize one trusted owner only.\n')
    print(f'N6 owner credentials saved privately: {access}')


if __name__ == '__main__':
    main()
