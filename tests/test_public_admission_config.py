"""Operator budgets must reach the adapter and metadata without credentials."""
import importlib.util
import json
import os
import subprocess
import shutil
import re
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
def load(name):
    spec=importlib.util.spec_from_file_location(name, ROOT/'Deployment'/(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
N6=load('n6_adapter');N7=load('n7_container')

class AdmissionConfig(unittest.TestCase):
    def test_n6_reports_only_configured_ingress_policy(self):
        with patch.dict(os.environ,{},clear=True):self.assertEqual(N6.public_admission_settings(),{})
        with patch.dict(os.environ,{'N6_ADMISSION_ENABLED':'yes','N6_CALLS_PER_MINUTE':'240','N6_CALL_BURST':'12'},clear=True):
            self.assertEqual(N6.public_admission_settings(),dict(rate_identity='client_ip',window_policy='leaky_bucket',rate_window_seconds=60,requests_per_minute=240,burst=12))
        for value in ('0','-1','abc','1.5','01','١'):
            with patch.dict(os.environ,{'N6_ADMISSION_ENABLED':'yes','N6_CALLS_PER_MINUTE':value},clear=True):
                with self.assertRaises(ValueError):N6.public_admission_settings()

    def test_n5_gateway_preserves_retained_http_routes(self):
        text=(ROOT/'Deployment/nginx.n5-admission.conf').read_text()
        expression=re.search(r'location ~ (\^.*\$) \{',text).group(1)
        route=re.compile(expression)
        for command in ['spawn','call','next','poll','stop','halt','abort','respond']:
            self.assertIsNotNone(route.fullmatch('/toplevel_'+command))
        for path in ['/admin/config','/admin/tokens','/tmp/token','/toplevel_arbitrary']:
            self.assertIsNone(route.fullmatch(path))

    def test_swi_operator_override_and_invalid_budget(self):
        executable=os.environ.get('STARTUP_TEST_SWIPL') or shutil.which('swipl')
        if not executable:self.skipTest('SWI-Prolog unavailable')
        base=[executable,'-f','none','-q','-s',str(ROOT/'Deployment/public_admission.pl'),'-g','public_admission:public_admission_options(O),writeq(O),halt']
        environment={k:v for k,v in os.environ.items() if not k.startswith('WP_')}
        good=subprocess.run(base,env=dict(environment,WP_RATE_WINDOW_SECONDS='30',WP_MAX_CALLS_PER_WINDOW='240',WP_MAX_SPAWNS_PER_WINDOW='180'),capture_output=True,text=True)
        self.assertEqual(good.returncode,0,good.stderr)
        self.assertIn('rate_window_seconds(30)',good.stdout)
        self.assertIn('max_call_requests_per_window(240)',good.stdout)
        self.assertIn('max_session_spawns_per_window(180)',good.stdout)
        bad=subprocess.run(base,env=dict(environment,WP_MAX_CALLS_PER_WINDOW='0'),capture_output=True,text=True)
        self.assertNotEqual(bad.returncode,0)
        self.assertIn('positive_integer_environment',bad.stderr)

    def test_n7_environment_replaces_existing_flag_without_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            config=Path(directory)/'adapter.json'
            config.write_text(json.dumps(dict(arguments=['--public','--public-max-engine-starts','20'])))
            env={'N7_CONFIG':str(config),'N7_PUBLIC_MAX_ENGINE_STARTS':'120','N7_PUBLIC_MAX_ENGINES':'4','N7_PUBLIC_MAX_ENGINES_PER_CLIENT':'2'}
            with patch.dict(os.environ,env,clear=True),patch.object(N7.sys,'argv',['n7_container.py']),patch.object(N7.os,'execv') as execute:
                N7.main()
            args=execute.call_args.args[1]
            self.assertEqual(args.count('--public-max-engine-starts'),1)
            self.assertEqual(args[args.index('--public-max-engine-starts')+1],'120')
            self.assertEqual(args[args.index('--public-max-engines')+1],'4')

    def test_n7_invalid_environment_stops_before_exec(self):
        with tempfile.TemporaryDirectory() as directory:
            config=Path(directory)/'adapter.json';config.write_text('{"arguments":[]}')
            with patch.dict(os.environ,{'N7_CONFIG':str(config),'N7_PUBLIC_MAX_ENGINE_STARTS':'0'},clear=True),patch.object(N7.sys,'argv',['n7_container.py']),patch.object(N7.os,'execv') as execute:
                with self.assertRaises(ValueError):N7.main()
                execute.assert_not_called()

if __name__=='__main__':unittest.main()
