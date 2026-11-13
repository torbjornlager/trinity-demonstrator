"""Compare the same deliberately stopped relay through the isolated TLS stack."""
import json
import sys
import audit_client
import wire

audit_client.codec = lambda: wire
events = []
receive_json = wire.WebSocket.recv_json


def capture_event(socket):
    event = receive_json(socket)
    events.append(event)
    return event


wire.WebSocket.recv_json = capture_event
mode = sys.argv[1]
reporter = audit_client.JsonlReporter('/tmp/' + mode + '-stages.jsonl')
try:
    session = audit_client.Session('wss://n5.elfenbenstornet.se/ws',
                                  'https://n5.elfenbenstornet.se', reporter=reporter)
except audit_client.StageFailure as error:
    timing = error.report
    assert timing['stage'] == 'transport_welcome', timing
    if mode == 'before':
        assert timing['outcome'] == 'local_watchdog_timeout', timing
        assert timing['watchdog']['fired'], timing
    else:
        assert timing['outcome'] == 'protocol_error', timing
        assert timing['event_types'] == ['error'], timing
        assert 'existence_error(websocket_relay,' in str(events[-1]), events
        assert not timing['watchdog']['fired'], timing
        assert timing['elapsed_seconds'] < timing['watchdog']['deadline_seconds'], timing
    print(json.dumps(dict(result='pass',expected_failure=timing,events=events)))
else:
    session.close()
    raise AssertionError('A stopped relay must not produce a successful welcome')
