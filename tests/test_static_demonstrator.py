"""Static packaging preserves the UI/service boundary and needs no server routes."""
from pathlib import Path
import json
import re
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import package_demonstrator as package

class StaticDistribution(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.output=Path(self.temp.name)/'site'
    def test_versioned_tree_has_real_assets_and_static_examples(self):
        m=package.build(self.output,'/releases/0.1.0/',allow_dirty=True)
        self.assertEqual(m['browser']['revision'],json.loads((ROOT/'dependencies/swi-wasm-node.json').read_text())['revision'])
        self.assertFalse(any(p.is_symlink() for p in self.output.rglob('*')))
        html=(self.output/'index.html').read_text()
        self.assertIn('src="/releases/0.1.0/editor_frame.html?',html)
        self.assertIn('normalized.pathname = "/demonstrator"',html) # Remote node navigation is not rewritten.
        self.assertIn('url.pathname = "/releases/0.1.0/index.html"',html) # Local tutorial navigation is.
        index=json.loads((self.output/'examples_index.json').read_text())
        queens=next(e for e in index['actors'] if e['name']=='01 queens.pl')
        self.assertEqual(queens['url'],'/releases/0.1.0/examples/actors/01%20queens.pl')
        self.assertEqual((self.output/'wasm/shared_db.pl').read_bytes(),(ROOT/'prolog/web_prolog/wasm/shared_db.pl').read_bytes())
        self.assertEqual((self.output/'swipl-bundle.js').read_bytes(),(ROOT/'web/swipl-bundle.js').read_bytes())
        css=(self.output/'vendor/fonts/ibm-plex-mono.css').read_text()
        fonts=re.findall(r'url\(([^)]+)\)',css)
        self.assertTrue(fonts)
        for url in fonts:
            self.assertTrue(url.startswith('/releases/0.1.0/vendor/fonts/'))
            self.assertTrue((self.output/url.removeprefix('/releases/0.1.0/')).is_file())

        self.assertNotIn('/admin.html',m['files'])
        package.verify(self.output)
    def test_remote_node_configuration_does_not_replace_asset_urls(self):
        m=package.build(self.output,'/release/',node='https://node.example',allow_dirty=True)
        html=(self.output/'index.html').read_text()
        self.assertIn('"nodeUrl":"https://node.example/"',html)
        self.assertIn('src="/release/vendor/trinity-host.js"',html)
        self.assertIn('this.requestJson("/call"',html)
        api=(self.output/'examples/APIs/ws-example-1.html').read_text()
        self.assertIn('return TrinityHost.websocket()',api)
    def test_corruption_or_extra_file_rejected(self):
        package.build(self.output,allow_dirty=True)
        (self.output/'unexpected').touch()
        with self.assertRaisesRegex(ValueError,'inventory'):package.verify(self.output)
        (self.output/'unexpected').unlink();(self.output/'index.html').write_text('corrupt')
        with self.assertRaisesRegex(ValueError,'hashes'):package.verify(self.output)
    def test_invalid_deployment_inputs(self):
        for value in ['//outside/','/../','/a/../../','/release?x/','relative/']:
            with self.subTest(value=value),self.assertRaises(ValueError):package.prefix_path(value)
        for value in ['file:///tmp/node','https://u:secret@node.example','https://node.example/?token=secret']:
            with self.subTest(value=value),self.assertRaises(ValueError):package.node_url(value)
    def test_release_build_rejects_dirty_source(self):
        with patch.object(package.subprocess,'check_output',side_effect=['a'*40,' M web/demonstrator.html']):
            with self.assertRaisesRegex(ValueError,'clean source'):package.build(self.output)
        self.assertFalse(self.output.exists())

if __name__=='__main__':unittest.main()
