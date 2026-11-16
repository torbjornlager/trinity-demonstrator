#!/usr/bin/env python3
"""Run the packaged N7 adapter with mounted owner configuration."""
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


def main():
    config = Path(os.environ.get('N7_CONFIG', '/run/n7/adapter.json'))
    args = json.loads(config.read_text())['arguments']
    if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise ValueError('N7 configuration requires a list of adapter arguments')
    if '--healthcheck' in sys.argv:
        port = args[args.index('--port') + 1]
        origin = args[args.index('--private-origin') + 1]
        request = Request('http://127.0.0.1:' + port + '/node_info',
                          headers={'Host': urlsplit(origin).netloc})
        with urlopen(request, timeout=3) as response:
            info = json.load(response)
        if info.get('profile') != 'actor' or info.get('auth') != 'open':
            raise RuntimeError('N7 public ACTOR listener is not ready')
        return
    if '--bind' in args:
        raise ValueError('The container controls its private listener address')
    if os.environ.get('N7_ENGINE_IMAGE'):
        args[args.index('--pilot-image') + 1] = os.environ['N7_ENGINE_IMAGE']
    os.execv(sys.executable, [sys.executable, '/app/experiments/eclipse-clp/isotope_http.py',
                             '--bind', '0.0.0.0', *args])


if __name__ == '__main__':
    main()
