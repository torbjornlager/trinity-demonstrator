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
        for key in list(self.env):
            if key.startswith('WP_') or key in ['SWI_HOME_DIR','SWIPL_HOME_DIR']:
                self.env.pop(key,None)
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
    def test_runtime_version_and_threads_gate(self):
        for version,threads,accepted in [(100103,'true',False),(100118,'true',False),
                                          (100119,'true',True),(100200,'true',True),
                                          (100119,'false',False)]:
            with self.subTest(version=version,threads=threads):
                goal=(f'catch(demonstrator_startup:require_runtime({version},{threads}),'
                      'E,(print_message(error,E),halt(2)))')
                r=self.run_swi(ROOT/'demonstrator_startup.pl',goal)
                self.assertEqual(r.returncode,0 if accepted else 2,r.stderr)
                if not accepted:self.assertIn('10.1.19',r.stderr)
    def test_public_url_validation_on_check_and_startup_paths(self):
        self.setup()
        for url in ['node.example.com','//node.example.com','ftp://node.example.com',
                    'https://','https://node.example.com:abc','https://node.example.com:0',
                    'https://node.example.com:65536','https://node.example.com/path',
                    'https://node.example.com?query=1','https://user@node.example.com']:
            for check in ['1','0']:
                with self.subTest(url=url,check=check):
                    r=self.run_swi(ROOT/'Deployment/start_node.pl',
                                   env=dict(self.env,WP_CHECK=check,WP_PUBLIC_URL=url))
                    self.assertEqual(r.returncode,2,r.stderr)
                    self.assertIn('public_url',r.stderr)
                    self.assertNotIn('Configuration OK',r.stdout)
    def test_valid_public_urls_pass_check_mode(self):
        self.setup()
        for url in ['', 'https://node.example.com', 'HTTPS://node.example.com', 'http://localhost:8080/',
                    'http://[::1]:3060']:
            with self.subTest(url=url):
                r=self.run_swi(ROOT/'Deployment/start_node.pl',
                               env=dict(self.env,WP_CHECK='1',WP_PUBLIC_URL=url))
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertIn('Configuration OK',r.stdout)
    def test_public_url_validation_is_pure_and_startup_applies_settings(self):
        r=self.run_swi(ROOT/'Deployment/start_node.pl',
                       "setting(http:public_host,Before),"
                       "public_url_settings('https://node.example.com',_),"
                       "setting(http:public_host,Before),"
                       "apply_public_url([public_url-'HTTPS://node.example.com:8443/']),"
                       "setting(http:public_scheme,https),"
                       "setting(http:public_host,'node.example.com'),"
                       "setting(http:public_port,8443),halt")
        self.assertEqual(r.returncode,0,r.stderr)
    def test_ipv6_public_url_round_trips_to_advertised_origin(self):
        self.setup()
        for origin in ['https://[::1]:8443','https://[::1]',
                       'http://[2001:db8::1]:3060']:
            with self.subTest(origin=origin):
                goal=(f"apply_public_url([public_url-'{origin}']),"
                      f"node:server_url(3060,URL),URL=='{origin}',halt")
                r=self.run_swi(ROOT/'load.pl',goal,
                               prefix=['-s',str(ROOT/'Deployment/start_node.pl')])
                self.assertEqual(r.returncode,0,r.stderr)
    def test_config_file_acknowledgement_and_environment_override(self):
        self.setup()
        config=self.work/'node.conf'
        config.write_text('auth = open.\nack_public = yes.\n')
        env=dict(self.env,WP_CONFIG=str(config),WP_CHECK='1')
        r=self.run_swi(ROOT/'Deployment/start_node.pl',env=env)
        self.assertEqual(r.returncode,0,r.stderr)
        r=self.run_swi(ROOT/'Deployment/start_node.pl',env=dict(env,WP_ACK_PUBLIC='no'))
        self.assertEqual(r.returncode,2,r.stderr)
        self.assertIn('WP_ACK_PUBLIC',r.stderr)
    def test_config_file_owner_shared_database_overlay_and_seed(self):
        config=self.work/'node.conf'
        config.write_text("owner = alice.\nshared_db_file = '/tmp/explicit.pl'.\n"
                          "shared_db_overlay_file = '/tmp/overlay.pl'.\n"
                          "discovery_seed_file = '/tmp/seed.pl'.\n")
        goal=("load_config_file,owner_option(private,[owner(alice)]),"
              "shared_db_option([load_shared_db_file('/tmp/explicit.pl')]),"
              "env_atom('WP_DISCOVERY_SEED_FILE','', '/tmp/seed.pl'),"
              "retractall(config_value(shared_db_file,_)),"
              "assertz(node_startup_options:default_node_shared_db_file('/tmp/default.pl')),"
              "shared_db_option([load_shared_db_file('/tmp/default.pl'),load_shared_db_file('/tmp/overlay.pl')]),halt")
        r=self.run_swi(ROOT/'Deployment/start_node.pl',goal,
                       dict(self.env,WP_CONFIG=str(config)))
        self.assertEqual(r.returncode,0,r.stderr)
        r=self.run_swi(ROOT/'Deployment/start_node.pl',
                       "load_config_file,owner_option(private,[owner(bob)]),"
                       "shared_db_option([load_shared_db_file('/tmp/env.pl')]),"
                       "env_atom('WP_DISCOVERY_SEED_FILE','', '/tmp/env-seed.pl'),halt",
                       dict(self.env,WP_CONFIG=str(config),WP_OWNER='bob',
                            WP_SHARED_DB_FILE='/tmp/env.pl',WP_DISCOVERY_SEED_FILE='/tmp/env-seed.pl'))
        self.assertEqual(r.returncode,0,r.stderr)
    def test_runner_times_out_and_continues_to_next_tier(self):
        self.setup()
        fake=self.work/'fake-swipl'
        fake.write_text('#!/usr/bin/env python3\nimport sys,time\n'
                        'if any(arg.endswith("/tests/tiers/t0_actors.pl") for arg in sys.argv): time.sleep(60)\n')
        fake.chmod(0o755)
        r=subprocess.run(['bash',str(ROOT/'tools/test.sh'),'T0','SERVICE_TEXT'],
                         env=dict(self.env,SWIPL=str(fake),TEST_TIER_TIMEOUT_SECONDS='2'),
                         capture_output=True,text=True,timeout=20)
        self.assertEqual(r.returncode,1,r.stdout+r.stderr)
        self.assertIn('Tier T0 timed out',r.stderr)
        self.assertIn('Tier SERVICE_TEXT',r.stdout)
    def test_runner_uses_pinned_tiers_and_demonstrator_assets(self):
        relative=tempfile.TemporaryDirectory(prefix='relative-runner-',dir=ROOT/'.trinity')
        self.addCleanup(relative.cleanup)
        self.work=Path(relative.name)
        self.state=self.work/'state.json'
        self.env['WP_NATIVE_STATE']=os.path.relpath(self.state,ROOT)
        state=self.setup()
        capture=self.work/'commands.jsonl'
        fake=self.work/'record-swipl'
        fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                        'files=[a for a in sys.argv if a.endswith(("t0_actors.pl","t4_node.pl","demonstrator_integration_tests.pl"))]\n'
                        'if files:\n'
                        '    with open(os.environ["TEST_RUNNER_CAPTURE"],"a") as out:\n'
                        '        out.write(json.dumps(dict(file=files[0],cwd=os.getcwd(),goal=sys.argv[sys.argv.index("-g")+1],state=os.environ["WP_NATIVE_STATE"],assets=os.environ["WP_ASSET_ROOT"],wasm=os.environ["WP_WASM_SOURCE_DIR"]))+"\\n")\n')
        fake.chmod(0o755)
        r=subprocess.run(['bash',str(ROOT/'tools/test.sh'),'T0','T4','DEMONSTRATOR'],
                         env=dict(self.env,SWIPL=os.path.relpath(fake,ROOT),TEST_RUNNER_CAPTURE=str(capture)),
                         capture_output=True,text=True,timeout=20)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        rows=[json.loads(line) for line in capture.read_text().splitlines()]
        self.assertEqual([Path(row['file']) for row in rows],
                         [NATIVE/'tests/tiers/t0_actors.pl',NATIVE/'tests/tiers/t4_node.pl',
                          NATIVE/'tests/tiers/t4_node.pl',
                          ROOT/'tests/demonstrator_integration_tests.pl'])
        self.assertEqual([Path(row['cwd']) for row in rows],[NATIVE,NATIVE,NATIVE,ROOT])
        self.assertIn('(run_native)',rows[1]['goal'])
        self.assertIn('(run_integration)',rows[2]['goal'])
        self.assertTrue(all(Path(row['state'])==self.state for row in rows))
        self.assertTrue(all(Path(row['assets'])==ROOT for row in rows))
        self.assertTrue(all(row['wasm']==state['wasm_root'] for row in rows))
    def test_t4_integration_runs_after_native_failure_or_timeout(self):
        self.setup()
        fake=self.work/'fake-swipl'
        fake.write_text('#!/usr/bin/env python3\nimport os,sys,time\n'
                        'if "t4_node.pl" in " ".join(sys.argv):\n'
                        '    goal=sys.argv[sys.argv.index("-g")+1]\n'
                        '    if "(run_native)" in goal:\n'
                        '        if os.environ["FAILURE_MODE"]=="timeout":time.sleep(60)\n'
                        '        sys.exit(7)\n'
                        '    print("integration-executed")\n')
        fake.chmod(0o755)
        for mode in ['failure','timeout']:
            with self.subTest(mode=mode):
                r=subprocess.run(['bash',str(ROOT/'tools/test.sh'),'T4'],
                                 env=dict(self.env,SWIPL=str(fake),FAILURE_MODE=mode,
                                          TEST_TIER_TIMEOUT_SECONDS='1'),
                                 capture_output=True,text=True,timeout=20)
                self.assertEqual(r.returncode,1,r.stdout+r.stderr)
                self.assertIn('integration-executed',r.stdout)
    def test_runner_rejects_modified_upstream_tests_before_execution(self):
        native=self.clone()
        self.setup(native)
        tier=native/'tests/tiers/t0_actors.pl'
        tier.write_text(tier.read_text()+'\nchanged_test.\n')
        marker=self.work/'executed'
        fake=self.work/'record-swipl'
        fake.write_text('#!/usr/bin/env python3\nfrom pathlib import Path\n'
                        f'Path({str(marker)!r}).touch()\n')
        fake.chmod(0o755)
        r=subprocess.run(['bash',str(ROOT/'tools/test.sh'),'T0'],
                         env=dict(self.env,SWIPL=str(fake)),
                         capture_output=True,text=True,timeout=20)
        self.assertEqual(r.returncode,2,r.stdout+r.stderr)
        self.assertIn('native test files differ from pinned revision',r.stderr)
        self.assertFalse(marker.exists())
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
