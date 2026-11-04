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
    def test_bad_shape_and_trailing_terms_fail_without_leaking(self):
        for text in ["[fixture_secret].", "['https://peer.example'-fixture_secret]. unexpected.","['https://peer.example'-secret(leak)]."]:
            with self.subTest(text=text):
                r=self.check(text)
                self.assertNotEqual(r.returncode,0)
                self.assertIn('invalid_peer_transport_tokens_file',r.stdout+r.stderr)
                self.assertNotIn('fixture_secret',r.stdout+r.stderr)
                self.assertNotIn('secret(leak)',r.stdout+r.stderr)
if __name__=='__main__':unittest.main()
