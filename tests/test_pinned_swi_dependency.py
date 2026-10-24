"""Pin violations must fail before native loading; original trees stay untouched."""
from pathlib import Path
import json,os,shutil,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
NATIVE=Path(os.environ.get('PINNED_SWI_TEST_ROOT',ROOT.parent/'swi-prolog-node')).resolve()

def tool(native,*args):
    return subprocess.run([sys.executable,str(ROOT/'tools/pinned_swi.py'),'--native-root',str(native),*map(str,args)],capture_output=True,text=True)

class PinnedDependency(unittest.TestCase):
    def clone(self,folder):
        dest=Path(folder)/'native'
        subprocess.run(['git','clone','--quiet','--no-hardlinks',str(NATIVE),str(dest)],check=True)
        return dest
    def test_exact_pin_is_accepted(self):
        result=tool(NATIVE,'--check')
        self.assertEqual(result.returncode,0,result.stderr)
        expected=json.loads((ROOT/'dependencies/swi-prolog-node.json').read_text())
        self.assertEqual(json.loads(result.stdout)['revision'],expected['revision'])
    def test_missing_checkout_does_not_fall_back(self):
        with tempfile.TemporaryDirectory() as d:
            result=tool(Path(d)/'missing','--check')
            self.assertNotEqual(result.returncode,0)
    def test_wrong_revision_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            native=self.clone(d)
            subprocess.run(['git','-C',str(native),'-c','user.name=Test Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','--allow-empty','-m','different revision'],check=True)
            result=tool(native,'--check')
            self.assertNotEqual(result.returncode,0)
            self.assertIn('revision mismatch',result.stderr)
    def test_dirty_schema_is_rejected_at_same_commit(self):
        with tempfile.TemporaryDirectory() as d:
            native=self.clone(d);source=native/'prolog/web_prolog/wasm/sxml_schema.pl'
            source.write_text(source.read_text()+'\nchanged_schema.\n')
            result=tool(native,'--check')
            self.assertNotEqual(result.returncode,0)
            self.assertIn('differ from pinned revision',result.stderr)
    def test_untracked_runtime_module_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            native=self.clone(d);(native/'prolog/untracked.pl').write_text('unexpected.\n')
            result=tool(native,'--check')
            self.assertNotEqual(result.returncode,0)
    def test_browser_drift_is_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as d:
            payload=Path(d)/'browser'
            subprocess.run([sys.executable,str(ROOT/'tools/package_wasm_prolog.py'),'--native-root',str(NATIVE),'--browser-root',str(ROOT),'--output',str(payload)],check=True,stdout=subprocess.DEVNULL)
            (payload/'sxml_schema.pl').write_text('wrong_schema.\n')
            result=tool(NATIVE,'--swipl',sys.executable,'--wasm-dir',payload,'--','-q')
            self.assertNotEqual(result.returncode,0)
            self.assertIn('assembled browser source differs',result.stderr)

if __name__=='__main__':unittest.main()
