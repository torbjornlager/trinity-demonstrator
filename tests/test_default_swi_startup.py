"""Public startup entry points share a fail-closed pin and no legacy fallback."""
from pathlib import Path
import json,os,shutil,socket,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
NATIVE=Path(os.environ.get('PINNED_SWI_TEST_ROOT',ROOT.parent/'swi-prolog-node')).resolve()
EXE=Path(os.environ['STARTUP_TEST_SWIPL'])

class DefaultStartup(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.work=Path(self.temp.name);self.state=self.work/'state.json'
        self.env=dict(os.environ)
        for key in ['WP_NATIVE_MODE','WP_NATIVE_STATE','SWI_HOME_DIR','SWIPL_HOME_DIR','WP_ASSET_ROOT','WP_WASM_SOURCE_DIR','WP_CONFIG_FILE']:self.env.pop(key,None)
        self.env['WP_NATIVE_STATE']=str(self.state)
    def setup(self,native=NATIVE):
        r=subprocess.run([sys.executable,str(ROOT/'tools/setup_swi.py'),'--native-root',str(native),'--state-file',str(self.state)],capture_output=True,text=True,timeout=20)
        self.assertEqual(r.returncode,0,r.stderr)
        return json.loads(r.stdout)
    def run_swi(self,entry,goal='true',env=None,prefix=()):
        return subprocess.run([str(EXE),'-f','none','-q',*prefix,'-s',str(entry),'-g',goal,'-t','halt'],cwd=self.work,env=env or self.env,capture_output=True,text=True,timeout=20)
    def clone(self):
        p=self.work/'native';subprocess.run(['git','clone','--quiet','--no-hardlinks',str(NATIVE),str(p)],check=True);subprocess.run(['git','-C',str(p),'checkout','--quiet','--detach',subprocess.check_output(['git','-C',str(NATIVE),'rev-parse','HEAD'],text=True).strip()],check=True);return p
    def test_default_from_foreign_directory(self):
        self.setup();r=self.run_swi(ROOT/'load.pl',"pinned_swi_bootstrap:check_origins,module_property(node,file(F)),writeln(F),node:node_manual_file(Manual),exists_file(Manual),node:node_wasm_module_file('sxml_schema.pl',Schema),exists_file(Schema)")
        self.assertEqual(r.returncode,0,r.stderr);self.assertIn(str(NATIVE/'prolog/web_prolog/node.pl'),r.stdout)
    def test_legacy_is_rejected_even_with_valid_setup(self):
        self.setup()
        r=self.run_swi(ROOT/'load.pl',env=dict(self.env,WP_NATIVE_MODE='legacy'))
        self.assertNotEqual(r.returncode,0);self.assertIn('native_startup_mode',r.stderr)
    def test_missing_setup_rejects_load_and_run(self):
        for entry in ['load.pl','run.pl']:
            with self.subTest(entry=entry):
                r=self.run_swi(ROOT/entry);self.assertNotEqual(r.returncode,0);self.assertIn('native SWI setup',r.stderr)
    def test_environment_startup_rejects_before_binding(self):
        with socket.socket() as reserved:
            reserved.bind(('127.0.0.1',0));reserved.listen();port=reserved.getsockname()[1]
            r=self.run_swi(ROOT/'Deployment/start_node.pl',env=dict(self.env,WP_PORT=str(port)))
        self.assertNotEqual(r.returncode,0);self.assertIn('native SWI setup',r.stderr);self.assertNotIn('Address already in use',r.stderr)
    def test_environment_check_mode_uses_pinned_dependency(self):
        self.setup()
        for mode in ['pinned']:
            with self.subTest(mode=mode):
                r=self.run_swi(ROOT/'Deployment/start_node.pl',env=dict(self.env,WP_NATIVE_MODE=mode,WP_CHECK='1'))
                self.assertEqual(r.returncode,0,r.stderr);self.assertIn('Configuration OK',r.stdout)
    def test_changed_runtime_rejects_before_binding(self):
        native=self.clone();self.setup(native);p=native/'prolog/web_prolog/actors.pl';p.write_text(p.read_text()+'\nchanged_runtime.\n')
        r=self.run_swi(ROOT/'Deployment/start_node.pl',env=dict(self.env,WP_CHECK='1'));self.assertNotEqual(r.returncode,0);self.assertIn('differ from pinned revision',r.stderr)
    def test_browser_drift_rejects(self):
        state=self.setup();p=Path(state['wasm_root'])/'sxml_schema.pl';p.write_text('changed.\n');r=self.run_swi(ROOT/'load.pl');self.assertNotEqual(r.returncode,0);self.assertIn('assembled browser source differs',r.stderr)
    def test_unknown_mode_is_not_legacy_fallback(self):
        r=self.run_swi(ROOT/'load.pl',env=dict(self.env,WP_NATIVE_MODE='unknown'));self.assertNotEqual(r.returncode,0);self.assertIn('native_startup_mode',r.stderr)
    def test_preloaded_local_module_cannot_satisfy_pin(self):
        self.setup();foreign=self.work/'actors.pl';shutil.copy2(NATIVE/'prolog/web_prolog/actors.pl',foreign);r=self.run_swi(ROOT/'load.pl',prefix=['-s',str(foreign)]);self.assertNotEqual(r.returncode,0);self.assertIn('native_origin_mismatch',r.stderr)
    def test_setup_preserves_corrupted_existing_payload(self):
        state=self.setup();p=Path(state['wasm_root'])/'sxml_schema.pl';p.write_text('keep_this.\n')
        r=subprocess.run([sys.executable,str(ROOT/'tools/setup_swi.py'),'--native-root',str(NATIVE),'--state-file',str(self.state)],capture_output=True,text=True)
        self.assertNotEqual(r.returncode,0);self.assertEqual(p.read_text(),'keep_this.\n')
    def test_standalone_native_loader_has_no_demonstrator_dependency(self):
        package=self.work/'package';package.mkdir()
        shutil.copytree(NATIVE/'prolog',package/'prolog')
        shutil.copy2(NATIVE/'load.pl',package/'load.pl')
        r=self.run_swi(package/'load.pl',"module_property(node,file(F)),writeln(F)",dict(self.env,PATH='/nonexistent'))
        self.assertEqual(r.returncode,0,r.stderr);self.assertIn(str(package/'prolog/web_prolog/node.pl'),r.stdout)
    def test_image_layout_uses_external_native_package(self):
        image=self.work/'image'
        for name in ['demonstrator_startup.pl','load.pl','Deployment/start_node.pl',
                     'dependencies/swi-prolog-node.json','dependencies/swi-wasm-node.json','tools/setup_swi.py',
                     'tools/pinned_browser.py',
                     'tools/pinned_swi.py','tools/package_wasm_prolog.py',
                     'tools/pinned_swi_bootstrap.pl']:
            dest=image/name;dest.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(ROOT/name,dest)
        shutil.copytree(ROOT/'prolog/web_prolog/wasm',image/'prolog/web_prolog/wasm',symlinks=True)
        sys.path.insert(0,str(ROOT/'tools'))
        import pinned_browser
        pin=json.loads((ROOT/'dependencies/swi-wasm-node.json').read_text())
        package=image/'.trinity/browser-runtime'/pin['revision']
        shutil.copytree(ROOT/'.trinity/browser-runtime'/pin['revision'],package)
        for local,remote in pinned_browser.aliases(False).items():
            link=image/local;link.parent.mkdir(parents=True,exist_ok=True)
            if link.exists() or link.is_symlink():link.unlink()
            link.symlink_to(os.path.relpath(image/'.trinity/browser-runtime/current'/remote,link.parent))
        state=image/'.trinity/native-swi.json'
        subprocess.run([sys.executable,str(image/'tools/setup_swi.py'),
                        '--native-root',str(NATIVE),'--state-file',str(state)],
                       check=True,stdout=subprocess.DEVNULL)
        r=self.run_swi(image/'Deployment/start_node.pl',
                       env=dict(self.env,WP_NATIVE_STATE=str(state),WP_CHECK='1'))
        self.assertEqual(r.returncode,0,r.stderr);self.assertIn('Configuration OK',r.stdout)
        self.assertFalse((image/'prolog/web_prolog/node.pl').exists())
    def test_runner_rejects_missing_setup_and_retired_tiers(self):
        missing=subprocess.run(['bash',str(ROOT/'tools/test.sh'),'T0'],
                               env=self.env,capture_output=True,text=True,timeout=10)
        self.assertNotEqual(missing.returncode,0);self.assertIn('native SWI setup',missing.stderr)
        retired=subprocess.run(['bash',str(ROOT/'tools/test.sh'),'T4_LEGACY_LAYOUT'],
                               env=self.env,capture_output=True,text=True,timeout=10)
        self.assertNotEqual(retired.returncode,0);self.assertIn('Unknown test tier',retired.stderr)
    def test_removed_native_sources_are_not_present(self):
        self.assertFalse((ROOT/'prolog/web_prolog.pl').exists())
        self.assertFalse((ROOT/'pack.pl').exists())
        self.assertFalse((ROOT/'prolog/web_prolog/wasm/sxml_schema.pl').exists())
        self.assertEqual(list((ROOT/'prolog/web_prolog').glob('*.pl')),[])

if __name__=='__main__':unittest.main()
