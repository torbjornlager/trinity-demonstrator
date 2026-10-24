"""Exercise pin routing and CI result accounting without changing runtime tests."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import ci_pinned_swi as ci

class PinnedCI(unittest.TestCase):
    def test_checkout_reads_manifest(self):
        pin=json.loads((ROOT/'dependencies/swi-prolog-node.json').read_text())
        self.assertEqual(ci.checkout_outputs(),dict(repository='torbjornlager/swi-prolog-node',revision=pin['revision']))
    def test_malformed_manifest_is_rejected(self):
        for bad in [dict(repository='https://elsewhere.invalid/node.git',revision='a'*40),
                    dict(repository='https://github.com/owner/node.git',revision='main\nother=value')]:
            with patch.object(Path,'read_text',return_value=json.dumps(bad)):
                with self.assertRaises(ValueError):ci.checkout_outputs()
    def test_native_and_integration_tiers_use_external_checkout(self):
        rows=ci.plan(Path('/external/native'),Path('/assembled'),'/verified/swipl')
        tiers=[r for r in rows if r[2][:2]==['bash','tools/test.sh'] and r[0]!='WASM']
        self.assertEqual([r[0] for r in tiers],['LINT','T0','T1_NATIVE','T2','T3_NATIVE','T4_NATIVE','T5','T1_INTEGRATION','T3_INTEGRATION','T4_INTEGRATION'])
        self.assertTrue(all(r[1]==Path('/external/native') for r in tiers))
        self.assertIn('pinned_swi_bootstrap:check_origins',rows[0][2][-3])
        equivalence=next(r for r in rows if r[0]=='browser-equivalence')
        self.assertIn('/external/native',equivalence[2]);self.assertIn('/assembled',equivalence[2])
    def test_failure_does_not_skip_remaining_checks(self):
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)
            rows=[('fails',ROOT,[sys.executable,'-c','raise SystemExit(7)']),
                  ('passes',ROOT,[sys.executable,'-c','print("executed")'])]
            self.assertEqual(ci.run_checks(rows,{},out),1)
            self.assertEqual([r['exit_code'] for r in json.loads((out/'results.json').read_text())],[7,0])
            self.assertIn('executed',(out/'passes.log').read_text())
    def test_process_timeout_is_reported_as_failure(self):
        with tempfile.TemporaryDirectory() as d:
            row=ci.run_one('wait',ROOT,[sys.executable,'-c','import time; time.sleep(30)'],{},Path(d),timeout=0.05)
            self.assertEqual(row['exit_code'],124)
    def test_wrong_pin_fails_before_creating_output(self):
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/'evidence'
            with patch.object(ci,'validate',side_effect=ValueError('wrong pin')):
                with patch.object(sys,'argv',['ci','--native-root',d,'--output',str(out)]):
                    self.assertEqual(ci.main(),2)
            self.assertFalse(out.exists())

if __name__=='__main__':unittest.main()
