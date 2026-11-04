import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


adapter = module('n6_adapter', 'Deployment/n6_adapter.py')
fetch = module('fetch_gprolog', 'tools/fetch_gprolog.py')
setup = module('setup_n6', 'tools/setup_n6.py')


class N6BoundaryTests(unittest.TestCase):
    def test_session_cookie_rejects_tampering_expiry_and_server_restart(self):
        import time
        from email.message import Message
        server = adapter.Server(('127.0.0.1', 0), None, '', 'fixture')
        other = adapter.Server(('127.0.0.1', 0), None, '', 'fixture')
        def headers(value):
            result = Message()
            result['Cookie'] = 'n6_owner=' + value
            return result
        try:
            valid = server.session()
            self.assertTrue(server.authorized(headers(valid)))
            self.assertFalse(other.authorized(headers(valid)))
            self.assertFalse(server.authorized(headers(valid + 'x')))
            expiry, nonce, _ = valid.split(':')
            old = str(int(time.time()) - 1) + ':' + nonce
            signature = adapter.hmac.new(server.session_key, ('owner:' + old).encode(), 'sha256').hexdigest()
            self.assertFalse(server.authorized(headers(old + ':' + signature)))
            self.assertFalse(server.authorized(headers('broken')))
            login = server.session('login', 600)
            self.assertTrue(server.valid_session(login, 'login'))
            self.assertFalse(server.authorized(headers(login)))
        finally:
            server.server_close()
            other.server_close()

    def test_owner_authentication_rejects_wrong_and_malformed_credentials(self):
        salt = bytes(range(16))
        digest = hashlib.pbkdf2_hmac('sha256', b'fixture-password', salt, 200000).hex()
        encoded = f'pbkdf2_sha256:200000:{salt.hex()}:{digest}'
        def basic(value):
            return 'Basic ' + base64.b64encode(value.encode()).decode()
        self.assertTrue(adapter.owner_authorized(basic('owner:fixture-password'), encoded))
        for value in ['', 'Bearer fixture-password', 'Basic ???', basic('other:fixture-password'),
                      basic('owner:incorrect'), basic('owner')]:
            self.assertFalse(adapter.owner_authorized(value, encoded), value)

    def test_dependency_manifest_rejects_tags_and_unexpected_repositories(self):
        original = fetch.load_pin()
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'pin.json'
            for key, value in [('revision', 'latest'), ('repository', 'https://example.invalid/port.git')]:
                changed = dict(original, **{key: value})
                file.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    fetch.load_pin(file)

    def test_fetch_refuses_existing_directories_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for destination in [root, root / 'link']:
                if destination != root:
                    destination.symlink_to(root / 'missing')
                with self.assertRaisesRegex(ValueError, 'must not exist'):
                    fetch.fetch(fetch.load_pin(), destination, {})

    def test_credential_setup_is_private_and_does_not_rotate_existing_login(self):
        previous = setup.ROOT
        with tempfile.TemporaryDirectory() as directory:
            setup.ROOT = Path(directory)
            (setup.ROOT / 'Deployment').mkdir()
            try:
                setup.main()
                access = setup.ROOT / '.trinity/n6-access.txt'
                environment = setup.ROOT / 'Deployment/.env.n6'
                saved = access.read_bytes(), environment.read_bytes()
                self.assertEqual(access.stat().st_mode & 0o777, 0o600)
                self.assertEqual(environment.stat().st_mode & 0o777, 0o600)
                setup.main()
                self.assertEqual(saved, (access.read_bytes(), environment.read_bytes()))
                password = next(x[10:] for x in access.read_text().splitlines() if x.startswith('Password: '))
                encoded = environment.read_text().strip().split('=', 1)[1]
                authorization = 'Basic ' + base64.b64encode(('owner:' + password).encode()).decode()
                self.assertTrue(adapter.owner_authorized(authorization, encoded))
            finally:
                setup.ROOT = previous


if __name__ == '__main__':
    unittest.main()
