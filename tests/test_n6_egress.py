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
                self.assertEqual(headers['X-Web-Prolog-Query-Owner'],'a'*64)
                self.assertNotIn('Cookie',headers);self.assertNotIn('Authorization',headers)
                count=len(FakeConnection.calls)
                for url in ['http://n1.elfenbenstornet.se','https://127.0.0.1','https://169.254.169.254','https://n6.elfenbenstornet.se','https://n1.elfenbenstornet.se:444','https://owner:password@n1.elfenbenstornet.se','https://n1.elfenbenstornet.se/#fragment','https://n1.elfenbenstornet.se/\nfoo']:
                    self.assertEqual(fetch(url)[0],403,url)
                self.assertEqual(len(FakeConnection.calls),count)
                FakeConnection.status=302;self.assertEqual(fetch('https://n1.elfenbenstornet.se')[0],403)
                FakeConnection.status=200
                for body in [b'x'*(egress.MAX_BODY+1),b'bad\x00body',b'\xff']:
                    FakeConnection.body=body;self.assertIn(fetch('https://n1.elfenbenstornet.se')[0],(400,502))
        finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
