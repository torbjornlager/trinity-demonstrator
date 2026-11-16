"""prepare_n7_adapter overlays only adapter Python modules on a verified package."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import prepare_n7_adapter as prepare  # noqa: E402


class PrepareN7Adapter(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.release = self.tmp / 'release'
        files = {'experiments/eclipse-clp/isotope_http.py': 'packaged http\n',
                 'experiments/eclipse-clp/n7_actor_ws.py': 'packaged ws\n',
                 'experiments/eclipse-clp/actors.ecl': 'engine\n',
                 'shell/index.html': '<html>\n', 'Deployment/x': 'd\n',
                 'examples/e.pl': 'e.\n', 'wheels/w.whl': 'w\n'}
        hashes = {}
        for name, text in files.items():
            path = self.release / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            hashes[name] = hashlib.sha256(text.encode()).hexdigest()
        (self.release / 'manifest.json').write_text(json.dumps(dict(files=hashes, image_id='sha256:engine')))
        self.sources = self.tmp / 'eclipse-node'
        self.sources.mkdir()
        for name in ('isotope_http.py', 'n7_actor_ws.py', 'actors.ecl'):
            (self.sources / name).write_text('checkout ' + name + '\n')

    def test_both_adapter_modules_can_be_overlaid(self):
        out = self.tmp / 'out'
        prepare.prepare(self.release, out, [self.sources / 'isotope_http.py', self.sources / 'n7_actor_ws.py'])
        base = out / 'experiments/eclipse-clp'
        self.assertEqual((base / 'n7_actor_ws.py').read_text(), 'checkout n7_actor_ws.py\n')
        self.assertEqual((base / 'isotope_http.py').read_text(), 'checkout isotope_http.py\n')
        self.assertEqual((base / 'actors.ecl').read_text(), 'engine\n')
        record = json.loads((out / 'container-inputs.json').read_text())
        self.assertEqual(sorted(record['adapter_overlay']), ['experiments/eclipse-clp/isotope_http.py',
                                                             'experiments/eclipse-clp/n7_actor_ws.py'])

    def test_single_source_keeps_former_calling_convention(self):
        out = self.tmp / 'out'
        prepare.prepare(self.release, out, self.sources / 'isotope_http.py')
        self.assertEqual((out / 'experiments/eclipse-clp/n7_actor_ws.py').read_text(), 'packaged ws\n')

    def test_engine_files_cannot_be_overlaid(self):
        with self.assertRaisesRegex(ValueError, 'adapter-only'):
            prepare.prepare(self.release, self.tmp / 'out', [self.sources / 'actors.ecl'])
        self.assertFalse((self.tmp / 'out').exists())

    def test_a_module_is_overlaid_at_most_once(self):
        with self.assertRaisesRegex(ValueError, 'once'):
            prepare.prepare(self.release, self.tmp / 'out', [self.sources / 'n7_actor_ws.py'] * 2)


if __name__ == '__main__':
    unittest.main()
