#!/usr/bin/env python3
"""Check the owner-installed Linda interface through separate browser sessions."""
import argparse
from pathlib import Path
import socket
import sys
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ws-url', required=True)
    parser.add_argument('--origin', required=True)
    parser.add_argument('--header', action='append', default=[])
    parser.add_argument('--conformance-root', type=Path,
                        default=Path(__file__).resolve().parents[2] / 'trinity-conformance')
    args = parser.parse_args()
    sys.path.insert(0, str(args.conformance_root / 'runner'))
    from run import Candidate, Harness

    candidate = Candidate(args.ws_url, 'actor', 10, None, args.origin,
                          False, tuple(args.header))
    group = 'linda_test_' + uuid.uuid4().hex[:12]

    def success(harness, goal):
        harness.call(goal, '[limit(1)]')
        result = harness.recv_type('success', limit=64)
        assert result.get('more') is False, result

    def session(goal):
        with Harness(candidate) as harness:
            harness.spawn_shell()
            success(harness, goal)
            harness.halt()

    # No src_text/src_predicates: these operations are supplied by the owner.
    session(f'linda_out(message({group},hello))')
    session(f'linda_in(message({group},Message)),Message=hello')
    print('Producer disconnects; a separate consumer takes the message: passed')

    # Start a consumer first, prove it remains blocked, then signal from a
    # separate session. Socket timeout bounds the absence check, not Linda.
    with Harness(candidate) as consumer:
        consumer.spawn_shell()
        consumer.call(f'linda_in(ready({group}))', '[limit(1)]')
        consumer.ws.sock.settimeout(0.25)
        try:
            event = consumer.recv_type('success', limit=64)
        except socket.timeout:
            pass
        else:
            raise AssertionError(f'Consumer did not block: {event!r}')
        finally:
            consumer.ws.sock.settimeout(candidate.timeout)
        session(f'linda_out(ready({group}))')
        result = consumer.recv_type('success', limit=64)
        assert result.get('more') is False, result
        consumer.halt()
    print('A waiting consumer is released by another session: passed')

    session(f'linda_out(setting({group},colour,green))')
    session(f'linda_rd(setting({group},colour,Colour)),Colour=green')
    session(f'linda_rd(setting({group},colour,green))')
    session(f'linda_rdp(setting({group},colour,green)), '
            f'\\+linda_rdp(setting({group},missing,_)), '
            f'linda_inp(setting({group},colour,green)), '
            f'\\+linda_inp(setting({group},colour,_))')
    print('Shared reads preserve data; probes and take have the expected effects: passed')


if __name__ == '__main__':
    main()
