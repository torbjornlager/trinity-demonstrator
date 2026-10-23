"""Fail-closed packaging/equivalence checks; no engine or repository mutation."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def tool(name, *args):
    return subprocess.run([sys.executable, str(ROOT / 'tools' / name), *map(str, args)],
                          capture_output=True, text=True)


class ExtractionTools(unittest.TestCase):
    def test_existing_destination_is_not_touched(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            sentinel = root / 'keep.txt'
            sentinel.write_text('keep')
            result = tool('rehearse_swi_repository_extraction.py', '--destination',
                          root, '--report-dir', root / 'report')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('destination must not exist', result.stderr)
            self.assertEqual(sentinel.read_text(), 'keep')
            self.assertFalse((root / 'report').exists())

    def test_native_boundary_keeps_schema_but_not_browser_engine(self):
        spec = importlib.util.spec_from_file_location(
            'extraction', ROOT / 'tools/rehearse_swi_repository_extraction.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(module.native_path('prolog/web_prolog/wasm/sxml_schema.pl'))
        self.assertFalse(module.native_path('prolog/web_prolog/wasm/statechart_wasm.pl'))
        self.assertFalse(module.native_path('web/manual.html'))
        self.assertTrue(module.native_path('tests/tiers/t5_interop.pl'))
        self.assertTrue(module.native_path('pack.pl'))

    def test_package_uses_native_schema_and_detects_drift(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            native = root / 'native'
            browser = root / 'browser'
            relative = Path('prolog/web_prolog/wasm')
            shutil.copytree(ROOT / relative, browser / relative)
            shutil.copytree(ROOT / relative, native / relative)
            for name in ['statechart_exec.pl', 'statechart_runtime.pl']:
                shutil.copy2(ROOT / 'prolog/web_prolog' / name,
                             native / 'prolog/web_prolog' / name)
            (browser / relative / 'sxml_schema.pl').write_text('stale browser schema')
            output = root / 'assembled'
            args = ('--native-root', native, '--browser-root', browser, '--output', output)
            result = tool('package_wasm_prolog.py', *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((output / 'sxml_schema.pl').read_bytes(),
                             (native / relative / 'sxml_schema.pl').read_bytes())
            self.assertNotEqual(tool('package_wasm_prolog.py', *args).returncode, 0)
            equiv = ('--native-root', native, '--wasm-dir', output)
            result = tool('check_statechart_wasm_equivalence.py', *equiv)
            self.assertEqual(result.returncode, 0, result.stderr)
            (output / 'sxml_schema.pl').write_text('mismatch')
            result = tool('check_statechart_wasm_equivalence.py', *equiv)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('package revisions differ', result.stderr)
            shutil.copy2(native / relative / 'sxml_schema.pl', output / 'sxml_schema.pl')
            with (output / 'statechart_wasm_exec.pl').open('a') as f:
                f.write('\nunexpected_changed_algorithm.\n')
            result = tool('check_statechart_wasm_equivalence.py', *equiv)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('shared microstep algorithm: FAIL', result.stderr)


if __name__ == '__main__':
    unittest.main()
