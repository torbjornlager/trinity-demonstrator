"""Trealla pin admission and real Git fetches without network access or Docker."""
from copy import deepcopy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import fetch_trealla
import pinned_trealla


class TreallaPins(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.pin = pinned_trealla.load_pin()

    def repository(self, kind):
        source = self.work / kind
        source.mkdir()
        subprocess.run(['git', 'init', '--quiet', str(source)], check=True)
        for name in pinned_trealla.REQUIRED_FILES[kind]:
            file = source / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('fixture\n')
        subprocess.run(['git', '-C', str(source), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(source), '-c', 'user.name=Pin Fixture',
                        '-c', 'user.email=fixture@example.invalid', 'commit',
                        '--quiet', '-m', 'pinned fixture'], check=True)
        record = deepcopy(self.pin if kind == 'port' else self.pin['engine'])
        record['revision'] = pinned_trealla.git(source, 'rev-parse', 'HEAD')
        return source, record

    def test_manifest_requires_full_commits_and_known_repositories(self):
        for kind in ['port', 'engine']:
            for key, value in [('revision', 'v3.14.20'), ('revision', 'a' * 39),
                               ('revision', 'a' * 40 + '\n'),
                               ('repository', 'https://example.invalid/runtime.git')]:
                with self.subTest(kind=kind, key=key, value=value):
                    pin = deepcopy(self.pin)
                    record = pin if kind == 'port' else pin['engine']
                    record[key] = value
                    file = self.work / 'pin.json'
                    file.write_text(json.dumps(pin))
                    with self.assertRaises(ValueError):
                        pinned_trealla.load_pin(file)

    def test_manifest_rejects_non_numeric_engine_version(self):
        self.pin['engine']['version'] = 'latest'
        file = self.work / 'pin.json'
        file.write_text(json.dumps(self.pin))
        with self.assertRaises(ValueError):
            pinned_trealla.load_pin(file)

    def test_clean_checkout_is_accepted(self):
        for kind in ['port', 'engine']:
            source, record = self.repository(kind)
            self.assertEqual(pinned_trealla.validate_checkout(source, record, kind),
                             record['revision'])

    def test_wrong_revision_is_rejected(self):
        source, record = self.repository('port')
        record['revision'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'revision differs'):
            pinned_trealla.validate_checkout(source, record, 'port')

    def test_modified_and_untracked_sources_are_rejected(self):
        source, record = self.repository('port')
        tracked = source / 'web_prolog.pl'
        tracked.write_text('modified\n')
        with self.assertRaisesRegex(ValueError, 'sources differ'):
            pinned_trealla.validate_checkout(source, record, 'port')
        tracked.write_text('fixture\n')
        (source / 'untracked.pl').write_text('untracked\n')
        with self.assertRaisesRegex(ValueError, 'sources differ'):
            pinned_trealla.validate_checkout(source, record, 'port')

    def test_subdirectory_cannot_impersonate_checkout_root(self):
        source, record = self.repository('port')
        with self.assertRaisesRegex(ValueError, 'checkout root'):
            pinned_trealla.validate_checkout(source / 'Deployment', record, 'port')

    def test_fetch_selects_exact_commit_and_labels_engine_version(self):
        for kind in ['port', 'engine']:
            source, record = self.repository(kind)
            destination = self.work / (kind + '-fetched')
            # Redirect the fixed GitHub URL to our synthetic Git repository.
            env = dict(os.environ, GIT_CONFIG_COUNT='1',
                       GIT_CONFIG_KEY_0='url.' + source.as_uri() + '.insteadOf',
                       GIT_CONFIG_VALUE_0=record['repository'], GIT_TERMINAL_PROMPT='0')
            fetch_trealla.fetch(record, destination, kind, env)
            self.assertEqual(pinned_trealla.validate_checkout(destination, record, kind),
                             record['revision'])
            if kind == 'engine':
                self.assertEqual(pinned_trealla.git(destination, 'describe', '--tags'),
                                 'v' + record['version'])

    def test_fetch_never_overwrites_existing_directory_or_symlink(self):
        _, record = self.repository('port')
        destination = self.work / 'occupied'
        destination.mkdir()
        marker = destination / 'keep'
        marker.write_text('unchanged')
        with self.assertRaisesRegex(ValueError, 'must not exist'):
            fetch_trealla.fetch(record, destination, 'port', dict(os.environ))
        self.assertEqual(marker.read_text(), 'unchanged')
        link = self.work / 'broken-link'
        link.symlink_to(self.work / 'missing')
        with self.assertRaisesRegex(ValueError, 'must not exist'):
            fetch_trealla.fetch(record, link, 'port', dict(os.environ))

    def test_authentication_stays_in_environment_and_preserves_git_config(self):
        token = self.work / 'token'
        token.write_text('fixture-only-not-a-real-token')
        from unittest.mock import patch
        with patch.dict(os.environ, {'GIT_CONFIG_COUNT': '1',
                                     'GIT_CONFIG_KEY_0': 'protocol.file.allow',
                                     'GIT_CONFIG_VALUE_0': 'always'}):
            env = fetch_trealla.fetch_environment(token)
        self.assertEqual(env['GIT_CONFIG_COUNT'], '2')
        self.assertEqual(env['GIT_CONFIG_KEY_0'], 'protocol.file.allow')
        self.assertEqual(env['GIT_CONFIG_KEY_1'], 'http.https://github.com/.extraheader')
        self.assertTrue(env['GIT_CONFIG_VALUE_1'].startswith('AUTHORIZATION: basic '))
        self.assertEqual(token.read_text(), 'fixture-only-not-a-real-token')


if __name__ == '__main__':
    unittest.main()
