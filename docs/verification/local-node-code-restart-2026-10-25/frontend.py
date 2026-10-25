"""Local n5 UI facade: demonstrator assets from n3, native API from Trealla."""
import argparse,http.server,http.client,socket,select
API={'/ws','/call','/node_info','/version','/healthz','/readyz','/metrics',
     '/toplevel_spawn','/toplevel_call','/toplevel_next','/toplevel_poll',
     '/toplevel_stop','/toplevel_halt','/toplevel_abort','/toplevel_respond'}
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_GET(self):self.forward()
    def do_POST(self):self.forward()
    def do_DELETE(self):self.forward()
    def forward(self):
        path=self.path.split('?',1)[0]
        port=self.server.backend if path in API or path.startswith('/admin/') else self.server.assets
        if path=='/ws':
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=10) as upstream:
                    upstream.settimeout(None)
                    upstream.sendall((self.requestline+'\r\n'+''.join(k+': '+v+'\r\n' for k,v in self.headers.items())+'\r\n').encode('iso-8859-1'))
                    while True:
                        ready,_,_=select.select([upstream,self.connection],[],[],60)
                        if not ready:break
                        for source in ready:
                            data=source.recv(65536)
                            if not data:return
                            (self.connection if source is upstream else upstream).sendall(data)
            finally:self.close_connection=True
            return
        upstream=http.client.HTTPConnection('127.0.0.1',port,timeout=30)
        try:
            body=self.rfile.read(int(self.headers.get('Content-Length','0')))
            headers={k:v for k,v in self.headers.items() if k.lower() not in ['connection','accept-encoding','host']}
            upstream.request(self.command,self.path,body,headers)
            response=upstream.getresponse();data=response.read()
            self.send_response(response.status)
            for key,value in response.getheaders():
                if key.lower() not in ['transfer-encoding','content-length','connection']:self.send_header(key,value)
            self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        except (OSError,http.client.HTTPException):self.send_error(502,'Local node unavailable')
        finally:upstream.close()
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=3060);p.add_argument('--backend',type=int,default=3062);p.add_argument('--assets',type=int,default=3053);a=p.parse_args()
    server=http.server.ThreadingHTTPServer(('127.0.0.1',a.port),Handler)
    server.backend=a.backend;server.assets=a.assets;server.serve_forever()
