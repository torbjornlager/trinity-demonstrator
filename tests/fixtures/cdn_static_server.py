"""Loopback-only static test server with a cookie-presence probe (never values)."""
import argparse,json
from functools import partial
from http.server import SimpleHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--directory',required=True);p.add_argument('--port',type=int,required=True);a=p.parse_args()
class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if urlsplit(self.path).path=='/fixture-cookie-presence':
            data=json.dumps({'fixture_cookie_present':'cdn_fixture_session=' in self.headers.get('Cookie','')}).encode()
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data);return
        return super().do_GET()
server=ThreadingHTTPServer(('127.0.0.1',a.port),partial(Handler,directory=a.directory))
try:server.serve_forever()
except KeyboardInterrupt:pass
finally:server.server_close()
