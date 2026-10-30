#!/usr/bin/env python3
"""Check N5 same-origin example loading through the browser protocol."""
import argparse
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ws-url', required=True)
    parser.add_argument('--header', action='append', default=[])
    parser.add_argument('--conformance-root', type=Path,
                        default=Path(__file__).resolve().parents[2] / 'trinity-conformance')
    args = parser.parse_args()
    sys.path.insert(0, str(args.conformance_root / 'runner'))
    from run import Candidate, Harness

    candidate = Candidate(args.ws_url, 'actor', 15, None,
                          'https://n5.elfenbenstornet.se', False, tuple(args.header))
    uri = 'https://n5.elfenbenstornet.se/examples/statecharts/01%20pause-and-resume.xml'
    with Harness(candidate) as harness:
        harness.spawn_shell()
        harness.call(
            f"statechart_spawn(P,[src_uri('{uri}'),trace(false),monitor(true)]),"
            "send(P,play),send(P,pause),send(P,resume),"
            "statechart_halt(P,true,2),"
            "receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)])",
            '[limit(1)]')
        result = harness.recv_type('success', limit=64)
        assert result.get('more') is False, result
        print('N5 same-origin statechart with encoded space: passed')
        for forbidden in [
            'https://n5.elfenbenstornet.se.invalid/chart.xml',
            'http://wp_n3:3053/examples/statecharts/01%20pause-and-resume.xml',
        ]:
            harness.call(
                f"catch(statechart_spawn(P,[src_uri('{forbidden}')]),E,true),"
                f"nonvar(E),E=error(permission_error(load,source_origin,'{forbidden}'),_),var(P)",
                '[limit(1)]')
            result = harness.recv_type('success', limit=64)
            assert result.get('more') is False, result
        print('Unlisted origins and direct internal URLs remain denied: passed')
        harness.halt()


if __name__ == '__main__':
    main()
