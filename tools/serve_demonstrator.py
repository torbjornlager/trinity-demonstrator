#!/usr/bin/env python3
"""Preview a verified static distribution; does not provide or proxy node APIs."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from package_demonstrator import verify
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--package',required=True,type=Path);p.add_argument('--port',type=int,default=0);a=p.parse_args()
root=a.package.resolve();manifest=verify(root);prefix=manifest['host']['assetBase']
class Handler(SimpleHTTPRequestHandler):
    def route(self):
        route=urlsplit(self.path)
        if not route.path.startswith(prefix):self.send_error(404);return False
        self.path='/'+route.path[len(prefix):]+('?' + route.query if route.query else '')
        return True
    def do_GET(self):
        if self.route():super().do_GET()
    def do_HEAD(self):
        if self.route():super().do_HEAD()
    def end_headers(self):
        self.send_header('Cache-Control','no-store')
        super().end_headers()
server=ThreadingHTTPServer(('127.0.0.1',a.port),partial(Handler,directory=str(root)))
print('http://localhost:'+str(server.server_port)+prefix+'index.html',flush=True)
try:server.serve_forever()
except KeyboardInterrupt:pass
finally:server.server_close()
