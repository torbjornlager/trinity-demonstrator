import importlib.util
import io
from http.server import HTTPServer
from pathlib import Path
import socket
import threading
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlencode
import urllib.request
import urllib.error
spec=importlib.util.spec_from_file_location('n6_egress',Path(__file__).resolve().parents[1]/'Deployment/n6_egress.py')
egress=importlib.util.module_from_spec(spec);spec.loader.exec_module(egress)

class EgressTests(unittest.TestCase):
    def test_absolute_deadline(self):
        left,right=socket.socketpair()
        stop=threading.Event()
        def drip():
            while not stop.wait(.02):
                try:right.sendall(b'x')
                except OSError:return
        t=threading.Thread(target=drip);t.start()
        stream=io.BufferedReader(egress.DeadlineReader(left,time.monotonic()+.15))
        started=time.monotonic()
        try:
            with self.assertRaises((TimeoutError,socket.timeout)):stream.read(100)
            self.assertLess(time.monotonic()-started,.4)
        finally:stop.set();left.close();right.close();t.join()

    def test_destination_and_response_policy(self):
        class FakeConnection:
            status=200;body=b'ok';calls=[]
            def __init__(self,*args):self.args=args
            def request(self,method,path,headers):self.calls.append((self.args,method,path,headers))
            def getresponse(self):return self
            def read(self,size):return self.body[:size]
            def close(self):pass
        server=HTTPServer(('127.0.0.1',0),egress.BrokerHandler)
        server.peers={'n1.elfenbenstornet.se':'81.229.12.212'};server.context=object()
        thread=threading.Thread(target=server.serve_forever);thread.start()
        def fetch(url,**extra):
            data=dict(url=url,purpose='rpc',query_owner='a'*64,timeout_ms='2000');data.update(extra)
            req=urllib.request.Request(f'http://127.0.0.1:{server.server_port}/fetch',urlencode(data).encode(),{'Content-Type':'application/x-www-form-urlencoded'})
            try:
                with urllib.request.urlopen(req) as r:return r.status,r.read()
            except urllib.error.HTTPError as e:return e.code,e.read()
        try:
            with patch.object(egress,'PinnedHTTPS',FakeConnection):
                self.assertEqual(fetch('https://n1.elfenbenstornet.se/call?goal=true'),(200,b'ok'))
                headers=FakeConnection.calls[-1][-1]
                self.assertEqual(headers['x-web-prolog-query-owner'],'a'*64)
                self.assertNotIn('Cookie',headers);self.assertNotIn('Authorization',headers)
                self.assertEqual(fetch('https://n1.elfenbenstornet.se/call', headers="X-Test: first\nx-test: second\nAuthorization: Bearer token\nUser-Agent: sample\nX-Empty: \nX-Unicode: 狐狸\n"), (200,b'ok'))
                headers=FakeConnection.calls[-1][-1]
                self.assertEqual(headers['x-test'], b'first')
                self.assertEqual(headers['authorization'], b'Bearer token')
                self.assertEqual(headers['user-agent'], b'sample')
                self.assertEqual(headers['x-empty'], b'')
                self.assertEqual(headers['x-unicode'], '狐狸'.encode('utf-8'))
                count=len(FakeConnection.calls)
                for bad in ['Host: unapproved.example\n', 'bad', 'X-Test: injected\r\n', 'X Test: value\n', 'X-Test: value\x00\n', 'X-Forwarded-For: impersonated\n', 'X_Web_Prolog_User: impersonated\n', 'x-web-prolog-query-owner: mismatch\n']:
                    self.assertEqual(fetch('https://n1.elfenbenstornet.se/call', headers=bad)[0],400,bad)
                self.assertEqual(fetch('https://n1.elfenbenstornet.se/source', purpose='source', headers='authorization: Bearer token\n')[0],400)
                self.assertEqual(len(FakeConnection.calls),count)
                for url in ['http://n1.elfenbenstornet.se','https://127.0.0.1','https://169.254.169.254','https://n6.elfenbenstornet.se','https://n1.elfenbenstornet.se:444','https://owner:password@n1.elfenbenstornet.se','https://n1.elfenbenstornet.se/#fragment','https://n1.elfenbenstornet.se/\nfoo']:
                    self.assertEqual(fetch(url)[0],403,url)
                self.assertEqual(len(FakeConnection.calls),count)
                FakeConnection.status=302;self.assertEqual(fetch('https://n1.elfenbenstornet.se')[0],403)
                FakeConnection.status=200
                for body in [b'x'*(egress.MAX_BODY+1),b'bad\x00body',b'\xff']:
                    FakeConnection.body=body;self.assertIn(fetch('https://n1.elfenbenstornet.se')[0],(400,502))
        finally:server.shutdown();server.server_close();thread.join()

    def test_lease_requires_budget_and_client_identity(self):
        import tempfile
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as d:
            lease=Path(d)/'20001'
            server=SimpleNamespace(leases=Path(d))
            real_fstat=egress.os.fstat
            def trusted_stat(fd):
                info=real_fstat(fd)
                return SimpleNamespace(st_uid=0,st_mode=info.st_mode,st_size=info.st_size)
            with patch.object(egress.os,'fstat',trusted_stat):
                lease.write_text('b'*64+'\n'+'c'*64+'\n')
                self.assertEqual(egress.Broker.lease(server,20001),('b'*64,'c'*64))
                for value in ['b'*64+'\n','b'*64+'\n'+'z'*64+'\n','b'*64+'\n'+'c'*63+'\n']:
                    lease.write_text(value)
                    with self.assertRaises(ValueError):egress.Broker.lease(server,20001)

    def test_local_rpc_is_fixed_endpoint_and_lease_budget(self):
        calls=[]
        class Controller:
            def __init__(self,port,timeout):self.port=port
            def request(self,method,path,headers):calls.append((self.port,path,headers))
            def getresponse(self):return self
            status=200
            def read(self,size):return b'success([ok],false).'
            def close(self):pass
        server=HTTPServer(('127.0.0.1',0),egress.BrokerHandler)
        server.peers={};server.context=object();server.local_rpc=(8081,'private-controller-token')
        # Real SO_PEERCRED/lease admission is qualified by the Linux container
        # tests; this fixture verifies route and header derivation at the handler.
        server.lease=lambda uid:('b'*64,'c'*64)
        thread=threading.Thread(target=server.serve_forever);thread.start()
        def fetch(url,**extra):
            data=dict(url=url,purpose='rpc',query_owner='a'*64,timeout_ms='2000');data.update(extra)
            req=urllib.request.Request(f'http://127.0.0.1:{server.server_port}/fetch',urlencode(data).encode(),{'Content-Type':'application/x-www-form-urlencoded'})
            try:
                with urllib.request.urlopen(req) as r:return r.status,r.read()
            except urllib.error.HTTPError as e:return e.code,e.read()
        try:
            with patch.object(egress,'LocalRPCConnection',Controller):
                self.assertEqual(fetch('http://localhost/call?goal=true'),(200,b'success([ok],false).'))
                port,path,headers=calls[-1]
                self.assertEqual(port,8081);self.assertEqual(path,'/call?goal=true')
                self.assertEqual(headers['authorization'],'Bearer private-controller-token')
                owner=headers['x-web-prolog-query-owner']
                self.assertEqual(len(owner),64);self.assertNotEqual(owner,'a'*64)
                self.assertEqual(headers['x-web-prolog-query-budget'],'b'*64)
                count=len(calls)
                for url in ['http://localhost/admin','http://localhost/','http://127.0.0.1/call','http://localhost:8081/call',
                            'http://localhost:80/call','http://localhost/call#x','http://user@localhost/call',
                            'http://localhost/%63all','http://localhost/other/../call']:
                    self.assertEqual(fetch(url)[0],403,url)
                self.assertEqual(fetch('http://localhost/call',purpose='source')[0],403)
                self.assertEqual(fetch('http://localhost/call',query_owner='')[0],403)
                self.assertEqual(fetch('http://localhost/call',headers='X-Web-Prolog-Query-Budget: forged\n')[0],400)
                self.assertEqual(len(calls),count)
                # Even a supplied Authorization field cannot select or expose
                # the controller credential; broker identity is authoritative.
                self.assertEqual(fetch('http://localhost/call',headers='Authorization: untrusted\n')[0],200)
                self.assertEqual(calls[-1][-1]['authorization'],'Bearer private-controller-token')
                self.assertEqual(calls[-1][-1]['x-web-prolog-query-owner'],owner)
                server.lease=lambda uid:('b'*64,'d'*64)
                self.assertEqual(fetch('http://localhost/call')[0],200)
                self.assertNotEqual(calls[-1][-1]['x-web-prolog-query-owner'],owner)
        finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
