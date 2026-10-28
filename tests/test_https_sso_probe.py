"""The real-SSO readiness probe records neither login redirects' secrets nor cookies."""
from pathlib import Path
from email.message import Message
import importlib.util,json,unittest
from unittest.mock import Mock,patch
from urllib.error import URLError
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('https_sso_probe',ROOT/'tools/probe-cdn-sso.py')
probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)
class SsoProbe(unittest.TestCase):
    def test_response_summary_excludes_secrets(self):
        headers=Message();headers['Location']='https://provider.example/authorize?state=PRIVATE_STATE&code=PRIVATE_CODE#PRIVATE_FRAGMENT'
        headers['Set-Cookie']='session=PRIVATE_COOKIE; Secure; HttpOnly'
        headers['X-Auth-Request-Email']='PRIVATE_IDENTITY'
        summary=probe.summarize_headers(headers)
        self.assertEqual(summary['redirect'],dict(scheme='https',host='provider.example',path='/authorize'))
        self.assertNotIn('PRIVATE_',json.dumps(summary))
    def test_only_plain_https_addresses_are_accepted(self):
        for value in ['http://node.example','https://user:secret@node.example','https://node.example/?token=secret','https://node.example/#secret']:
            with self.subTest(value=value),self.assertRaises(ValueError):probe.https_base(value)
        self.assertEqual(probe.https_base('https://node.example'),'https://node.example/')
        self.assertEqual(probe.https_base('https://ui.example/',True),'https://ui.example')
        with self.assertRaises(ValueError):probe.https_base('https://ui.example/path',True)
    def test_network_failure_is_unmeasured_not_a_cors_rejection(self):
        opener=Mock();opener.open.side_effect=URLError(TimeoutError())
        with patch.object(probe.urllib.request,'build_opener',return_value=opener):
            result=probe.probe('https://node.example/','https://ui.example')
        self.assertFalse(result['checks']['https_reachable'])
        self.assertIsNone(result['checks']['credentialed_json_preflight'])
        self.assertFalse(result['browser_sso_verified'])
        self.assertFalse(result['ready_for_browser_verification'])
    def test_redirects_are_not_followed(self):
        self.assertIsNone(probe.NoRedirect().redirect_request(None,None,302,'',Message(),'https://provider.example/?state=secret'))
if __name__=='__main__':unittest.main()
