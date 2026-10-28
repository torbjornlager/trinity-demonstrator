#!/usr/bin/env python3
"""Serve the isolated Studio experiment and existing local runtime assets."""
import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

HERE = Path(__file__).resolve().parent
WEB = HERE.parents[1] / 'web'

class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        path = unquote(urlsplit(path).path)
        root, relative = (WEB, path[len('/runtime/'):]) if path.startswith('/runtime/') else (HERE, path.lstrip('/'))
        parts = Path(relative).parts
        if '..' in parts:
            return str(HERE / '__invalid_path__')
        return str(root.joinpath(*parts))

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8092)
    args = parser.parse_args()
    for asset in ['vendor/codemirror.min.js', 'vendor/swi-wasm-node.js', 'swi_wasm_actor_worker.js', 'swipl-bundle.js']:
        if not (WEB / asset).is_file():
            parser.error('Missing ' + asset + '; complete the demonstrator runtime setup first.')
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    print('Trinity Studio: http://localhost:' + str(server.server_port) + '/', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
