"""Owner peer credentials must be destination-bound and absent from logs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
class PeerTransportSetup(unittest.TestCase):
    def check(self,text):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'peers.pl';p.write_text(text)
            env=dict(os.environ,WP_CHECK='1',WP_AUTH='private',WP_PEER_TRANSPORT_TOKENS_FILE=str(p))
            return subprocess.run([os.environ.get('SWIPL','swipl'),'-f','none','-q','-s',str(ROOT/'Deployment/start_node.pl')],cwd=ROOT,env=env,text=True,capture_output=True,timeout=20)
    def test_valid_credentials_are_redacted(self):
        r=self.check("['https://peer.example'-fixture_secret].\n")
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn('1 peers (redacted)',r.stdout)
        self.assertNotIn('fixture_secret',r.stdout+r.stderr)
    def test_named_launchers_receive_credentials_before_startup(self):
        for name,port in [('n3',3053),('n4',3055)]:
            with self.subTest(node=name),tempfile.TemporaryDirectory() as d:
                p=Path(d)/'peers.pl';p.write_text("['https://peer.example'-fixture_secret].")
                env=dict(os.environ,WP_PEER_TRANSPORT_TOKENS_FILE=str(p))
                launcher=ROOT/'Deployment'/('start_'+name+'.pl')
                goal=("use_module(library(prolog_wrap)),dynamic(seen_options/2),"
                      "wrap_predicate(node:node(P,O),capture,_,(assertz(user:seen_options(P,O)),throw(captured_startup))),"
                      f"load_files('{launcher}',[]),seen_options({port},Options),"
                      "memberchk(peer_transport_tokens(['https://peer.example'-fixture_secret]),Options),halt")
                r=subprocess.run([os.environ.get('SWIPL','swipl'),'-f','none','-q','-s',str(ROOT/'load.pl'),'-g',goal,'-t','halt(1)'],cwd=ROOT,env=env,text=True,capture_output=True,timeout=20)
                self.assertEqual(r.returncode,0,r.stdout+r.stderr)
                self.assertNotIn('fixture_secret',r.stdout+r.stderr)
    def test_cluster_peer_policy_allows_n5_and_rejects_external_destinations(self):
        for name,port in [('n3',3053),('n4',3055)]:
            with self.subTest(node=name):
                launcher=ROOT/'Deployment'/('start_'+name+'.pl')
                goal=("use_module(library(prolog_wrap)),dynamic(seen_options/2),"
                      "wrap_predicate(node:node(P,O),capture,_,(assertz(user:seen_options(P,O)),throw(captured_startup))),"
                      f"load_files('{launcher}',[]),seen_options({port},Options),"
                      "memberchk(load_uri_allowed_origins(Origins),Options),"
                      "source_utils:normalize_load_uri_allowed_origins(Origins,Normalized),"
                      "node_runtime_state:register_node_runtime(19483,_{load_uri_allowed_origins:Normalized}),"
                      "node_runtime_state:with_node_port_context(19483,("
                      "node_sandbox:reject_forbidden_spawn_option(actor,node('https://n5.elfenbenstornet.se')),"
                      "source_utils:enforce_source_uri_policy('https://n5.elfenbenstornet.se/test.pl','https://n5.elfenbenstornet.se/test.pl'),"
                      "catch(node_sandbox:reject_forbidden_spawn_option(actor,node('https://external.invalid')),E,true),"
                      "nonvar(E),E=error(permission_error(option,sandboxed,_),_),"
                      "catch(source_utils:enforce_source_uri_policy('https://external.invalid/test.pl','https://external.invalid/test.pl'),S,true),"
                      "nonvar(S),S=error(permission_error(load,source_uri,_),_))),halt")
                env=dict(os.environ);env.pop('WP_PEER_TRANSPORT_TOKENS_FILE',None)
                r=subprocess.run([os.environ.get('SWIPL','swipl'),'-f','none','-q','-s',str(ROOT/'load.pl'),'-g',goal,'-t','halt(1)'],cwd=ROOT,env=env,text=True,capture_output=True,timeout=20)
                self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    def test_bad_shape_and_trailing_terms_fail_without_leaking(self):
        for text in ["[fixture_secret].", "['https://peer.example'-fixture_secret]. unexpected.","['https://peer.example'-secret(leak)]."]:
            with self.subTest(text=text):
                r=self.check(text)
                self.assertNotEqual(r.returncode,0)
                self.assertIn('invalid_peer_transport_tokens_file',r.stdout+r.stderr)
                self.assertNotIn('fixture_secret',r.stdout+r.stderr)
                self.assertNotIn('secret(leak)',r.stdout+r.stderr)
if __name__=='__main__':unittest.main()
