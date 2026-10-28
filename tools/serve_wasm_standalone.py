#!/usr/bin/env python3
"""Serve pinned browser assets with the demonstrator’s assembled example payload.

For runtime-only distribution use swi-wasm-node/tools/serve.py.

Example: python3 tools/serve_wasm_standalone.py --prolog-root /assembled/payload
Open /vendor/swi-wasm-minimal.html. No native node or demonstrator page is loaded.
"""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
PAYLOADS = {'shared_db.pl', 'sxml_schema.pl', 'statechart_wasm.pl',
            'statechart_wasm_runtime.pl', 'statechart_wasm_model.pl', 'statechart_wasm_exec.pl'}

class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        route = urlsplit(path).path
        if route.startswith('/wasm/'):
            name = route.removeprefix('/wasm/')
            if name in PAYLOADS:
                return str(self.server.prolog_root / name)
            return str(self.server.prolog_root / '__not_found__')
        return super().translate_path(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prolog-root', required=True, type=Path)
    parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args()
    from pinned_browser import check
    check()
    payload = args.prolog_root.resolve(strict=True)
    for name in PAYLOADS:
        if not (payload / name).is_file():
            parser.error('missing assembled payload: ' + name)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=str(ROOT / 'web')))
    server.prolog_root = payload
    print(f'http://localhost:{server.server_port}/vendor/swi-wasm-minimal.html', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == '__main__':
    main()
