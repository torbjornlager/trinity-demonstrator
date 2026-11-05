"""N5 peer credentials must survive public-overlay volume replacement."""
import json,os,shutil,subprocess,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
@unittest.skipUnless(shutil.which('docker'),'Docker Compose CLI is required')
class N5PeerCompose(unittest.TestCase):
    def config(self,overlay,*,before_public=False):
        files=['compose.yaml','compose.trealla-n5.yaml']
        files+=([overlay,'compose.trealla-n5-public.yaml'] if before_public else ['compose.trealla-n5-public.yaml',overlay])
        cmd=['docker','compose','--env-file','/dev/null']
        for f in files:cmd+=['-f',str(ROOT/'Deployment'/f)]
        cmd+=['config','--format','json']
        env=dict(os.environ,WP_N5_OWNER='fixture@example.test',WP_TREALLA_N5_ADMIN_TOKEN='fixture_admin_123456789012345',WP_N5_PEER_TOKENS_FILE='/tmp/fixture-peers.pl',WP_N5_PEER_TOKENS_VOLUME='fixture_n5_peer_tokens',OAUTH2_PROXY_GITHUB_USERS='fixture',OAUTH2_PROXY_CLIENT_ID='fixture',OAUTH2_PROXY_CLIENT_SECRET='fixture',OAUTH2_PROXY_COOKIE_SECRET='fixture')
        r=subprocess.run(cmd,cwd=ROOT,env=env,capture_output=True,text=True,timeout=15)
        self.assertEqual(r.returncode,0,'Compose rejected the fixture configuration')
        return json.loads(r.stdout)
    def check_mount(self,overlay,target):
        n5=self.config(overlay)['services']['wp_n5'];mounts=n5['volumes']
        mount=next(m for m in mounts if m['target']==target)
        self.assertTrue(mount['read_only'])
        self.assertIn('/state',[m['target'] for m in mounts])
        self.assertIn('/var/log/webprolog',[m['target'] for m in mounts])
        self.assertEqual(n5['environment']['WP_PEER_TRANSPORT_TOKENS_FILE'],target if target.endswith('.pl') else target+'/peers.pl')
    def test_readonly_bind_keeps_public_state(self):
        self.check_mount('compose.peer-transport-n5.yaml','/run/secrets/peer-transport.pl')
    def test_readonly_volume_keeps_public_state(self):
        self.check_mount('compose.peer-transport-n5-volumes.yaml','/run/peer-transport')
    def test_wrong_overlay_order_discards_credentials(self):
        n5=self.config('compose.peer-transport-n5.yaml',before_public=True)['services']['wp_n5']
        self.assertNotIn('/run/secrets/peer-transport.pl',[m['target'] for m in n5['volumes']])
if __name__=='__main__':unittest.main()
