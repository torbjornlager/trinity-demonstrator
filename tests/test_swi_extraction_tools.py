"""Fail-closed packaging/equivalence checks; no engine or repository mutation."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NATIVE = Path(os.environ.get('PINNED_SWI_TEST_ROOT', ROOT / '.trinity/native'))


def tool(name, *args):
    return subprocess.run([sys.executable, str(ROOT / 'tools' / name), *map(str, args)],
                          capture_output=True, text=True)


class ExtractionTools(unittest.TestCase):
    def test_package_uses_native_schema_and_detects_drift(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            native = root / 'native'
            browser = root / 'browser'
            relative = Path('prolog/web_prolog/wasm')
            shutil.copytree(ROOT / relative, browser / relative)
            shutil.copytree(NATIVE / relative, native / relative)
            for name in ['statechart_exec.pl', 'statechart_runtime.pl']:
                shutil.copy2(NATIVE / 'prolog/web_prolog' / name,
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
