import sys,ssl,socket,threading,tempfile,subprocess,pathlib
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Deployment'))
from n6_egress import PinnedHTTPS
from unittest.mock import patch
with tempfile.TemporaryDirectory() as d:
 c=pathlib.Path(d)/'cert.pem';k=pathlib.Path(d)/'key.pem'
 subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(k),'-out',str(c),'-days','1','-subj','/CN=n1.elfenbenstornet.se','-addext','subjectAltName=DNS:n1.elfenbenstornet.se'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
 context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(c,k)
 listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(4)
 def serve():
  for _ in range(3):
   raw,_=listener.accept()
   try:
    with context.wrap_socket(raw,server_side=True) as conn:
     conn.recv(4096);conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')
   except ssl.SSLError:raw.close()
 t=threading.Thread(target=serve);t.start();original=socket.create_connection
 def redirect(address,timeout):return original(listener.getsockname(),timeout)
 trusted=ssl.create_default_context(cafile=str(c))
 with patch('socket.create_connection',redirect):
  for hostname,ctx,expected in [('n1.elfenbenstornet.se',trusted,True),('n2.elfenbenstornet.se',trusted,False),('n1.elfenbenstornet.se',ssl.create_default_context(),False)]:
   x=PinnedHTTPS(hostname,'127.0.0.1',1,ctx)
   try:
    x.request('GET','/');assert expected;assert x.getresponse().read()==b'ok'
   except ssl.SSLCertVerificationError:assert not expected
   finally:x.close()
 t.join();listener.close()
print('PASS real TLS: trusted approved hostname accepted, mismatched hostname and untrusted CA rejected')
