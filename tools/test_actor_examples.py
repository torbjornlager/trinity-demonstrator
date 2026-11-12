#!/usr/bin/env python3
"""Check shared prompt examples against disposable ACTOR endpoints and WASM.

The private JSON config supplies gate, nodes (name/ws/origin/peer, optional
headers and source_field), and optionally wasm_package. The gate must implement
GET /reset and /release: /call forwards to an isolated peer only after release.
Use --runner for the pinned runtime-contracts runner/run.py WebSocket client.
No fixtures or live services are started or changed by this driver.
"""
import argparse
import html
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.request import urlopen

WEB = Path(__file__).resolve().parents[1]


def cases(peer):
    text = (WEB / 'web/actor-profile-tutorial.html').read_text()
    assert (WEB / 'web/tutorial.html').read_text().count(
        'receive({prompt($Pid, Ref, Prompt) -&gt; true}).') == 1

    def snippet(name):
        match = re.search(r'<pre id="' + name + r'">(.*?)</pre>', text, re.S)
        return (html.unescape(match[1]).strip().removeprefix('?-').strip()
                .removesuffix('.').replace('$Pid', 'Pid').replace('$Ref', 'Ref'))

    return [
        ('tutorial', "toplevel_spawn(Pid,[session(true)])," +
         snippet('toplevel-call-input') + ",Prompt=='Input'," +
         snippet('toplevel-respond') +
         ",Answer=success(Pid,[input('Input',hello)],false),toplevel_halt(Pid)"),
        ('correlation', 'prompt_correlation_check'),
        ('expert-conversation', 'expert_example_check'),
        ('expert-agent', 'simulation([]),simulation([src_list([yellow(tweety)])])'),
        ('timeout-retry', 'asynch_test_2(Answer,Ref),Answer==timeout,'
         'writeln(timeout_observed),yield(Ref,Later),Later==success([a],false)'),
        ('callback-error', "promise('" + peer + "',true,Ref),"
         'catch(yield(Ref,_,[timeout(0),on_timeout(fail)]),E,true),nonvar(E),'
         'E=error(timeout_callback_failed(Ref),_),writeln(timeout_observed),'
         'yield(Ref,Later),Later=success(_,false)')]


def source(peer):
    return '\n'.join((WEB / p).read_text().replace(
        'https://n3.elfenbenstornet.se', peer) for p in [
            'examples/actors/19 promise-and-yield.pl',
            'examples/actors/20 expert-system-agent.pl',
            'tests/fixtures/prompt-correlation.pl'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--node', default='node')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('example_wire', args.runner)
    wire = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = wire
    spec.loader.exec_module(wire)
    config = json.loads(args.config.read_text())
    gate = config['gate']
    rows = []

    def control(action):
        with urlopen(gate + '/' + action, timeout=10) as reply:
            reply.read()

    def save():
        args.report.write_text(json.dumps(rows, indent=2) + '\n')

    for node in config['nodes']:
        ws = wire.WebSocket(node['ws'], 35, None, node['origin'], False,
                            node.get('headers', ()))
        try:
            ws.send_json(dict(command='transport_hello', version=1,
                              browser_pids=True, io_ack=True))
            assert ws.recv_json()['type'] == 'transport_welcome'
            code = source(node['peer'])
            spawn = dict(command='toplevel_spawn', options='[session(true)]')
            if node.get('source_field'):
                spawn['src_text'] = code
            else:
                spawn['options'] = '[session(true),src_text(' + json.dumps(code) + ')]'
            ws.send_json(spawn)
            event = ws.recv_json()
            assert event['type'] == 'spawned', event
            pid = event['pid']
            for name, goal in cases(node['peer']):
                if name in ('timeout-retry', 'callback-error'):
                    control('reset')
                ws.send_json(dict(command='toplevel_call', pid=pid, goal=goal,
                                  options='[limit(1),once(true)]'))
                output = []
                while True:
                    event = ws.recv_json()
                    kind = event['type']
                    if kind in ('io_request', 'output'):
                        nested = event.get('event', event)
                        text = nested.get('stdout', nested.get('data', ''))
                        output.append(text)
                        if 'timeout_observed' in text:
                            control('release')
                        if kind == 'io_request':
                            ws.send_json(dict(command='browser_io_reply',
                                              request_id=event['request_id'], status='ok'))
                    elif kind in ('success', 'failure', 'error'):
                        break
                    elif kind == 'prompt':
                        raise AssertionError('Actor prompt escaped its protocol caller')
                text = ''.join(output)
                passed = event['type'] == 'success'
                if name == 'expert-agent':
                    passed = passed and 'A1: Is ' in text and 'a good pet.' in text
                rows.append(dict(engine=node['name'], case=name, passed=passed,
                                 event=event, stdout=text, goal=goal))
                save()
        finally:
            ws.close()
            control('release')

    if config.get('wasm_package'):
        with tempfile.TemporaryDirectory(prefix='actor-examples-') as temp:
            temp = Path(temp)
            (temp / 'input.json').write_text(json.dumps(dict(
                source=source(gate), cases=cases(gate), gate=gate)))
            subprocess.run([args.node, str(WEB / 'tests/wasm/prompt_examples.cjs'),
                            str(Path(config['wasm_package']).resolve()),
                            str(temp / 'input.json'), str(temp / 'output.json')],
                           check=True, timeout=120)
            rows.extend(json.loads((temp / 'output.json').read_text())['rows'])
            save()
    print(json.dumps(dict(cases=len(rows), passed=sum(r['passed'] for r in rows))))
    return int(any(not r['passed'] for r in rows))


if __name__ == '__main__':
    sys.exit(main())
