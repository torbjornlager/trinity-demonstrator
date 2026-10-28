#!/usr/bin/env python3
"""Preview the Genealogist with a separately packaged swi-wasm-node runtime."""
import argparse
import json
import hashlib
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

HERE = Path(__file__).resolve().parent
DEFAULT = HERE.parents[1] / '.trinity/browser-runtime/current'

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, runtime, **kwargs):
        self.runtime = runtime
        super().__init__(*args, **kwargs)

    def translate_path(self, path):
        path = unquote(urlsplit(path).path)
        root, relative = (self.runtime, path[len('/runtime/'):]) if path.startswith('/runtime/') else (HERE, path.lstrip('/'))
        if Path(relative).is_absolute() or '..' in Path(relative).parts:
            return str(HERE / '__invalid_path__')
        return str(root / relative)

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8093)
    parser.add_argument('--runtime-package', type=Path, default=DEFAULT,
                        help='swi-wasm-node package directory containing manifest.json and web/')
    args = parser.parse_args()
    package = args.runtime_package.resolve()
    if not (package / 'manifest.json').is_file():
        parser.error('Choose an extracted swi-wasm-node package with --runtime-package.')
    manifest = json.loads((package / 'manifest.json').read_text())
    for asset in ['swi_wasm_actor_worker.js', 'vendor/swi-wasm-node.js', 'swipl-bundle.js', 'wasm/statechart_wasm.pl']:
        file = package / 'web' / asset
        if not file.is_file():
            parser.error('Incomplete runtime package: missing ' + asset)
        if hashlib.sha256(file.read_bytes()).hexdigest() != manifest.get('files', {}).get('web/' + asset):
            parser.error('Runtime manifest mismatch: ' + asset)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, runtime=package / 'web'))
    print('The Genealogist: http://localhost:' + str(server.server_port) + '/', flush=True)
    print('Runtime package: ' + str(package), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
