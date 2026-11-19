#!/usr/bin/env python3
"""Run the visible drawer exercises anonymously on owned loopback SWI nodes.

External node/source URLs are mapped to disposable local fixtures. Intentional
failure/error examples keep their expected outcomes. No live services are used.
"""
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading
import time
from urllib.parse import quote
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def queries(text):
    """Use the drawer's markers and blank-line query boundaries."""
    marker = '/** <examples>' if '/** <examples>' in text else '<!-- <examples>'
    if marker not in text:
        raise ValueError('example has no query block')
    block = text.split(marker, 1)[1].split('*/' if marker.startswith('/') else '-->', 1)[0]
    block = re.sub(r'^\s*%.*$', '', block, flags=re.M)
    return [part.strip().removesuffix('.') for part in
            re.split(r'^\s*\?-\s*', block, flags=re.M)[1:] if part.strip()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swipl', required=True)
    parser.add_argument('--native-root', type=Path, required=True)
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--only', help='one relative catalogue path or folder, for a focused control')
    args = parser.parse_args()
    args.native_root = args.native_root.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('open_exercise_wire', args.runner)
    wire = importlib.util.module_from_spec(spec)
    import sys
    sys.modules[spec.name] = wire
    spec.loader.exec_module(wire)
    lit = wire.prolog_quote_atom
    rows, inventory, expected_inventory = [], [], []
    expected_checks = 0
    source_text = b'ancestor_descendant(alice,bob). ancestor_descendant(bob,carol).\n'

    class Source(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Type', 'text/x-prolog; charset=utf-8')
            self.send_header('Content-Length', str(len(source_text)))
            self.end_headers()
            self.wfile.write(source_text)

    source = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Source)
    source_url = f'http://127.0.0.1:{source.server_port}'
    home, peer = free_port(), free_port()
    while peer == home:
        peer = free_port()
    url, peer_url = f'http://localhost:{home}', f'http://localhost:{peer}'
    threading.Thread(target=source.serve_forever, daemon=True).start()

    def adapt(text):
        for number in [1, 3, 4]:
            text = text.replace(f'https://n{number}.elfenbenstornet.se', peer_url)
        return text.replace('https://n2.elfenbenstornet.se', source_url)

    def save():
        (args.output/'results.json').write_text(json.dumps(dict(
            suite='demonstrator-open-exercises-0.1', authentication='none',
            scope='Visible drawer query sequences on owned OPEN loopback nodes',
            native_root=str(args.native_root), inventory=inventory,
            expected_inventory=expected_inventory, expected_checks=expected_checks,
            status=('pass' if expected_inventory and len(inventory)==len(expected_inventory)
                    and len(rows)==expected_checks and all(r['status']=='pass' for r in rows) else 'fail'),
            results=rows,
            counts={s: sum(r['status'] == s for r in rows) for s in ['pass', 'fail']}
        ), indent=2)+'\n')

    def harness():
        return wire.Harness(wire.Candidate(url.replace('http:', 'ws:')+'/ws',
                            'actor', 15, None, url, False, ()))

    def call(h, goal):
        h.call(goal, '[limit(1),once(true)]')
        events = []
        deadline = time.monotonic() + 15
        original_read = h.ws._recv_exact

        def bounded_read(count):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('query exceeded its 15-second deadline')
            h.ws.sock.settimeout(remaining)
            return original_read(count)

        # Enforce the deadline across transport ping/pong frames as well.
        h.ws._recv_exact = bounded_read
        try:
            while time.monotonic() < deadline:
                event = h.recv()
                events.append(event)
                if event.get('type') in ['success', 'failure', 'error'] and event.get('pid') == h.shell:
                    return event, events
                if event.get('type') == 'prompt':
                    h.send(dict(command='toplevel_respond', pid=event['pid'],
                                prompt_ref=event['prompt_ref'], input='yes'))
                else:
                    h.acknowledge_output(event)
            raise TimeoutError('query exceeded its 15-second deadline')
        except (TimeoutError, socket.timeout) as error:
            return dict(type='timeout', pid=h.shell, data=str(error)), events
        finally:
            h.ws._recv_exact = original_read


    try:
        with tempfile.TemporaryDirectory(prefix='open-exercises-') as tmp:
            boot = Path(tmp)/'node.pl'
            shared = 'human(socrates). mortal(X):-human(X). shared_fact(open_fixture). shared_transition_enabled.'
            options = (f'[auth(open),profile(actor),sandbox(blacklist),'
                       f'max_call_requests_per_window(1000),max_ws_actors_per_principal(256),'
                       f'load_shared_db_text({lit(shared)}),'
                       f'load_uri_allowed_origins([{lit(source_url)}]),'
                       f'load_uri_allowed_ip_ranges([\'127.0.0.0/8\'])]')
            boot.write_text(f":- use_module({lit(str(args.native_root/'prolog/web_prolog.pl'))}).\n"
                            ":- use_module(library(socket)).\n"
                            ":- initialization(main,main).\n"
                            "open_node(Port,Options) :- tcp_socket(S),tcp_bind(S,ip(127,0,0,1):Port),tcp_listen(S,128),node(Port,[tcp_socket(S)|Options]).\n"
                            f'main :- open_node({home},{options}),open_node({peer},{options}),thread_get_message(stop).\n')
            env = dict(os.environ, WP_ASSET_ROOT=str(ROOT))
            for key in ['SWI_HOME_DIR', 'SWIPL_HOME_DIR', 'WP_NATIVE_STATE']:
                env.pop(key, None)
            with (args.output/'fixture.log').open('w') as log:
                process = subprocess.Popen([args.swipl, '-f', 'none', '-q', str(boot)],
                                           env=env, stdout=log, stderr=log)
                try:
                    for _ in range(200):
                        if process.poll() is not None:
                            raise RuntimeError('OPEN fixture exited; inspect fixture.log')
                        try:
                            with urlopen(url+'/node_info', timeout=.2) as response:
                                info = json.load(response)
                            break
                        except OSError:
                            time.sleep(.04)
                    else:
                        raise RuntimeError('OPEN fixture readiness timeout')
                    assert info['auth'] == 'open', info
                    with urlopen(url+'/examples_index', timeout=5) as response:
                        index = json.load(response)
                    html = (ROOT/'web/demonstrator.html').read_text()
                    mode = re.search(r'var HIDE_EXPERIMENTAL_EXAMPLES\s*=\s*(true|false)\s*;', html)
                    visibility = re.search(r'var hidden = example.kind === "statechart"\s*\?\s*(\[[0-9, ]+\])\s*:\s*(\[[0-9, ]+\])', html)
                    if not mode or not visibility:
                        raise ValueError('unrecognized drawer curation; review the exercise inventory')
                    curated = mode[1] == 'true'
                    hidden = dict(statecharts=set(json.loads(visibility[1])), actors=set(json.loads(visibility[2])))
                    for kind in ['actors', 'statecharts']:
                        for example in index[kind]:
                            number = int(example['name'].split(' ', 1)[0])
                            path = example['url']
                            selection = '/examples/'+args.only if args.only else None
                            selected = not selection or path == selection or (selection.endswith('/') and path.startswith(selection))
                            if selected and not (curated and number in hidden[kind]):
                                expected_inventory.append(path)
                    if not expected_inventory or len(set(expected_inventory)) != len(expected_inventory):
                        raise ValueError('empty or duplicate exercise inventory')
                    for kind in ['actors', 'statecharts']:
                        for example in index[kind]:
                            number = int(example['name'].split(' ', 1)[0])
                            if curated and number in hidden[kind]:
                                continue
                            path = example['url']
                            if args.only:
                                selection = '/examples/'+args.only
                                if path != selection and not (selection.endswith('/') and path.startswith(selection)):
                                    continue
                            with urlopen(url+quote(path, safe='/'), timeout=5) as response:
                                original = response.read().decode()
                            inventory.append(dict(path=path, sha256=hashlib.sha256(original.encode()).hexdigest()))
                            entry_queries = queries(original)
                            if not entry_queries:
                                raise ValueError('visible example has no executable queries: '+path)
                            expected_checks += len(entry_queries) + int(kind == 'actors' and number == 10)
                            bindings = {}
                            with harness() as h:
                                source_code = adapt(original) if kind == 'actors' else ''
                                h.spawn_shell('[session(true),src_text('+lit(source_code)+')]')
                                for i, query in enumerate(entry_queries, 1):
                                    query = re.sub(r'\$([A-Z][A-Za-z0-9_]*)', lambda m: bindings[m[1]], adapt(query))
                                    query = query.replace('<editor>', lit(adapt(original)))
                                    expected = 'failure' if number == 13 and kind == 'actors' and i == 2 else 'success'
                                    if kind == 'actors' and (number, i) in [(13, 3), (16, 6)]:
                                        expected = 'error'
                                    event, events = call(h, query)
                                    passed = event['type'] == expected
                                    if expected == 'error':
                                        passed = passed and ('type_error' if number == 13 else 'server_down(false)') in str(event)
                                    if event['type'] == 'success' and event.get('data'):
                                        bindings.update(event['data'][0])
                                    rows.append(dict(path=path, query=i, goal=query, expected=expected,
                                                     event=event, events=events, status='pass' if passed else 'fail'))
                                    save()
                                    if not passed and not (kind == 'actors' and number == 13):
                                        break
                                if kind == 'actors' and number == 10:
                                    goal = ('self(S),spawn((spawn((receive({ping(F)->send(F,pong)}),'
                                            'receive({finish->true})),Child,[link(false)]),send(S,child(Child))),'
                                            'Parent,[monitor(true)]),receive({child(C)->true},[timeout(3)]),'
                                            'receive({down(Parent,Parent,true)->true},[timeout(3)]),'
                                            'send(C,ping(S)),receive({pong->true},[timeout(3)]),send(C,finish)')
                                    event, events = call(h, goal)
                                    rows.append(dict(path=path, query='unlink-survives-parent', goal=goal,
                                                     event=event, events=events,
                                                     status='pass' if event['type'] == 'success' else 'fail'))
                                    save()
                            print(path, 'checked', flush=True)
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    finally:
        source.shutdown()
        source.server_close()
        save()
    print(json.dumps(dict(entries=len(inventory), checks=len(rows), failed=sum(r['status']=='fail' for r in rows))))
    return int(json.loads((args.output/'results.json').read_text())['status'] != 'pass')


if __name__ == '__main__':
    raise SystemExit(main())
