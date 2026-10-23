# Native SWI spawn teardown cleanup — 2026-10-23

## Repair

`distribution:remote_drop_connection_locked/1` now tolerates ordinary failure as well as the already-tolerated exceptions from the WebSocket close handshake. The change is local: `ignore(best_effort(ws_close(...)))`. It does not alter the shared `best_effort/1` helper, protocols, shutdown policies, remote startup results or monitor handling. After an unsuccessful close attempt, local spawn-queue retirement and pending-event removal can still complete.

The correlated-spawn fixture now uses nested `call_cleanup/2` so its endpoint and diagnostic facts are removed even if connection disposal fails or throws. The adjacent legacy and malformed-answer mock endpoint fixtures use the same unconditional endpoint-removal pattern. Cleanup exceptions retain their existing propagation. This prevents a stopped fixture server's endpoint from being selected by a subsequent test.

The runtime README describes the local cleanup guarantee without claiming remote actor termination. The preceding configurable-asset work remains intact and uncommitted.

## Regression coverage

Two new test declarations each cover failure and exception variants:

- `connection_drop_finishes_after_unsuccessful_close`: inject an unsuccessful close for one synthetic socket, check connection/capability removal, actual queue destruction, queue-bookkeeping retirement and pending-event removal; preserve another connection, capability, pending event and queue message.
- `fixture_withdraws_endpoint_when_drop_fails_or_throws`: inject unsuccessful connection disposal and check unconditional endpoint/diagnostic removal, preserving the injected exception.

Injection uses test-thread-local faults and temporary `library(prolog_wrap)` wrappers, not production hooks. Wrappers are inert for other threads/connections and removed by cleanup.

The four focused variants pass. Disposable red controls establish that these tests detect the old defects: restoring the old runtime close path fails the ordinary-failure variant; restoring the old fixture cleanup fails both endpoint/diagnostic-removal variants. Logs and commands are in `red-control-results.json`, `red-runtime.log`, and `red-fixture.log`.

The entire `toplevel_correlation_transport` group also passes, including negotiated error isolation, correlated/legacy startup rejection, connection loss, malformed answers, canonical answer negotiation and direct asynchronous transport checks (`transport-group.log`).

## Full T4 runs

The first full T4 invocation stopped progressing at `node:isobase_yield_timeout_callback_is_sandboxed`, before reaching the new tests. The test process was terminated at an external 180-second watchdog; test assertions and timeouts were not edited (`t4.log`, `t4-first-watchdog.json`).

The next fresh-process full T4 run reached the end. All repaired transport tests passed. One separate assertion failed: `cross_node_lifecycle:explicit_monitor_2_carries_user_ref` consumed a down notification with a different pid/reference. This intermittent failure was already recorded before this repair in the configurable-assets investigation. It remains unchanged and is not claimed fixed here (`t4-retry.log`, `t4-retry-results.json`).

A final fresh-process full T4 run includes the final queue-destruction assertion. It passed all 1,002 reported test declarations (including their forall variants), exit 0, in 51.474 seconds (`t4-final.log`, `t4-final-results.json`). The earlier stalled run and intermittent monitor failure remain recorded separately; a passing rerun does not establish that those issues are resolved.

## Preservation and provenance

- Engine: separate PCRE-enabled SWI build containing Jan's `09b6299` fix; exact executable/hash in `preservation.json`.
- Existing assertion and timeout lines are retained; the new regressions add assertions without weakening old tests.
- Installed SWI/Trealla binary hashes and n3/n5 process identities/commands remain unchanged.
- The only runtime source changed during this repair is `prolog/web_prolog/distribution.pl`.
- `repair.patch` is relative to the start of this repair, including the preceding diagnostic instrumentation. `source-hashes.json` identifies its before/after source contents.
- No engine installation, node restart, commit or push was performed.

