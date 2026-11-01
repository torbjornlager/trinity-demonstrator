"""Consumer rejects a changed external runtime or asset alias before startup."""
import hashlib
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('pinned_browser_under_test', ROOT/'tools/pinned_browser.py')
browser=importlib.util.module_from_spec(spec);spec.loader.exec_module(browser)

class BrowserDependency(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        self.root=Path(temp.name);self.base=self.root/'.trinity/browser-runtime'
        (self.root/'dependencies').mkdir()
        shutil.copy2(ROOT/'dependencies/swi-prolog-node.json',self.root/'dependencies/swi-prolog-node.json')
        self.pin=json.loads((ROOT/'dependencies/swi-wasm-node.json').read_text())
        self.package=self.base/self.pin['revision']
        shutil.copytree(ROOT/'.trinity/browser-runtime'/self.pin['revision'],self.package)
        self.pinpath=self.root/'pin.json';self.pinpath.write_text(json.dumps(self.pin))
        self.old=(browser.ROOT,browser.BASE,browser.PIN)
        browser.ROOT,browser.BASE,browser.PIN=self.root,self.base,self.pinpath
        self.addCleanup(self.restore)
        (self.base/'current').symlink_to(self.package.name,target_is_directory=True)
        for local,remote in browser.aliases(False).items():
            link=self.root/local;link.parent.mkdir(parents=True,exist_ok=True)
            link.symlink_to(self.package/remote)
    def restore(self):browser.ROOT,browser.BASE,browser.PIN=self.old
    def rewrite_manifest(self,change):
        p=self.package/'manifest.json';m=json.loads(p.read_text());change(m)
        p.write_text(json.dumps(m));self.pin['manifest_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
        self.pinpath.write_text(json.dumps(self.pin))
    def test_selected_package_and_runtime_aliases(self):
        self.assertEqual(browser.check()[0],self.package)
    def test_schema_provenance_must_match_native_pin(self):
        for field,value in [('repository','https://elsewhere.invalid/native.git'),
                            ('revision','0'*40),('path','unexpected.pl')]:
            with self.subTest(field=field):
                original=json.loads((self.package/'manifest.json').read_text())['schema'][field]
                self.rewrite_manifest(lambda m:m['schema'].update({field:value}))
                with self.assertRaisesRegex(ValueError,'schema provenance'):browser.check()
                self.rewrite_manifest(lambda m:m['schema'].update({field:original}))
    def test_schema_record_digest_is_checked(self):
        self.rewrite_manifest(lambda m:m['schema'].update(sha256='0'*64))
        with self.assertRaisesRegex(ValueError,'schema digest'):browser.check()
    def test_native_schema_bytes_are_checked(self):
        native=self.root/'native';schema=native/'prolog/web_prolog/wasm/sxml_schema.pl'
        schema.parent.mkdir(parents=True)
        schema.write_bytes((self.package/'web/wasm/sxml_schema.pl').read_bytes())
        self.assertEqual(browser.check(native)[0],self.package)
        schema.write_text('incompatible_schema.\n')
        with self.assertRaisesRegex(ValueError,'pinned native schema'):browser.check(native)
    def test_corrupt_asset(self):
        (self.package/'web/vendor/swi-wasm-node.js').write_text('changed')
        with self.assertRaisesRegex(ValueError,'files differ'):browser.check()
    def test_missing_or_extra_asset(self):
        extra=self.package/'unexpected';extra.touch()
        with self.assertRaisesRegex(ValueError,'inventory'):browser.check()
        extra.unlink();(self.package/'web/swipl-bundle.js').unlink()
        with self.assertRaisesRegex(ValueError,'inventory'):browser.check()
    def test_dirty_source_rejected(self):
        self.rewrite_manifest(lambda m:m['source'].update(dirty=True))
        with self.assertRaisesRegex(ValueError,'developmental'):browser.check()
    def test_manifest_pin_drift(self):
        (self.package/'manifest.json').write_text('{}')
        with self.assertRaisesRegex(ValueError,'manifest'):browser.check()
    def test_alias_replacement_rejected(self):
        p=self.root/'web/swi_wasm_actor_worker.js';p.unlink();p.write_text('local copy')
        with self.assertRaisesRegex(ValueError,'alias differs'):browser.check()
    def test_selected_revision_drift(self):
        p=self.base/'current';p.unlink();p.symlink_to('wrong')
        with self.assertRaisesRegex(ValueError,'selected browser'):browser.check()
    def test_escaping_symlink_rejected(self):
        p=self.package/'web/swipl-bundle.js';outside=self.root/'outside';outside.write_bytes(p.read_bytes());p.unlink();p.symlink_to(outside)
        with self.assertRaisesRegex(ValueError,'escaping'):browser.check()

if __name__=='__main__':unittest.main()
