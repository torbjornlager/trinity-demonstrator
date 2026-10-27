"""Container dependency fetches select a commit without persisting credentials."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import fetch_swi

class FetchSWI(unittest.TestCase):
    def test_fetches_exact_commit_into_a_new_checkout(self):
        native=Path(os.environ.get('PINNED_SWI_TEST_ROOT',ROOT/'.trinity/native')).resolve()
        with tempfile.TemporaryDirectory() as d:
            work=Path(d);manifest=work/'pin.json';destination=work/'native'
            pin=json.loads((ROOT/'dependencies/swi-prolog-node.json').read_text())
            pin['repository']=str(native);manifest.write_text(json.dumps(pin))
            token=work/'token';token.write_text('test-build-secret')
            with patch.object(fetch_swi,'PIN',manifest),patch.object(sys,'argv',['fetch','--destination',str(destination),'--token-file',str(token)]):
                fetch_swi.main()
            actual=subprocess.check_output(['git','-C',str(destination),'rev-parse','HEAD'],text=True).strip()
            self.assertEqual(actual,pin['revision'])
            config=(destination/'.git/config').read_text()
            self.assertNotIn('AUTHORIZATION',config)
            self.assertNotIn('test-build-secret',config)
            self.assertEqual(subprocess.check_output(['git','-C',str(destination),'status','--porcelain'],text=True),'')
            with patch.object(fetch_swi,'PIN',manifest),patch.object(sys,'argv',['fetch','--destination',str(destination),'--token-file',str(token)]):
                with self.assertRaises(SystemExit):fetch_swi.main()
            self.assertEqual(subprocess.check_output(['git','-C',str(destination),'rev-parse','HEAD'],text=True).strip(),actual)

if __name__=='__main__':unittest.main()
