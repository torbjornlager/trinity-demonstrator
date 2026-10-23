# Native SWI correlated-spawn teardown investigation — 2026-10-23

## Outcome

The failure reproduces on committed HEAD and with the pending asset-location changes. It is a teardown failure that contaminates the following fixture, rather than a mismatched correlated spawn reply. No runtime repair was made in this investigation.

The immediate failing operation is `websocket:ws_close/3`, which sometimes **fails** rather than throwing. `distribution:best_effort/1` catches exceptions but preserves ordinary failure. Consequently `remote_drop_connection_locked/1` fails before `close_spawn_queue/1` and the remaining cleanup. The fixture calls `remote_drop_connection/1` before retracting its endpoint override, so it also skips that retraction. Its enclosing server fixture nevertheless stops the HTTP server. The next fixture publishes a new endpoint for the same logical node, but the older fact remains first. Endpoint selection chooses that stopped server and reports `econnrefused` instead of `"startup rejected"`.

This is an application cleanup defect plus fragile test cleanup. The trace establishes the ordinary failure and its propagation; it does not establish why the underlying WebSocket operation fails internally or establish an upstream SWI defect. A reader and the closing caller can both operate on the client socket during shutdown; that is a possible contributor, not a proved engine cause.

## Versions and method

- Committed baseline: `7926b56f28b6cc3f59318467ab3e556563ad78e9`.
- Comparison: that revision with the pending configurable-asset changes. The new asset tests occur later than this prefix.
- Both used the same separate, PCRE-enabled SWI build containing Jan's `09b6299` fix, not an installed engine.
- Both source versions were exported to disposable directories recorded in `snapshots.json`; both received identical test instrumentation.
- Three fresh-process prefixes per version, alternating baseline/assets. Original assertions and test timeouts were retained. An external 180-second process watchdog was never reached.
- Prefix: `lifetime_authority`, `node`, `public_goal_guard`, `sandbox_source_names`, `promise_yield`, `promise_lifecycle`, `promise_ownership`, `rpc_options`, `native_paging`, `toplevel_synch`, `toplevel_correlation_transport` (672 reported tests before forall expansion).

| Batch | Baseline | Asset changes |
| --- | --- | --- |
| Fixed prefix, stage diagnostics | 3/3 fail | 3/3 fail |
| Additional prefix, cleanup outcome and fail-port trace | 1/1 fail | 0/1 fail |
| Reduced two-test control, fail-port trace | 1/3 fail | 1/3 fail |

All six fixed-prefix failures are the unchanged startup-rejection assertion receiving a connection-refused transport error. The failing variant can be correlated or legacy, depending on which preceding teardown fails. These are small diagnostic batches, not failure-rate estimates; instrumentation changes scheduling.

## Reduced reproduction

`reduce.py` runs only these existing public test selections, in fresh processes:

1. `spawn_errors_isolated_on_negotiated_connection`
2. `matching_startup_failure_and_legacy_fallback` (its existing correlated/legacy variants)

The second trial failed on each version. Both reduced failing traces show:

```
ws_close_failed(ClientSocket,1000,"done")
drop_locked_failed('http://spawn-correlation.invalid')
drop_failed('http://spawn-correlation.invalid')
```

followed by a new fixture selecting the old endpoint. See `pair-baseline-02.events` and `pair-assets-02.events`. This reduction uses the existing test fixture and Web Prolog transport; it is not a standalone SWI-engine reproducer.

A particularly explicit prefix trace is `fail-port-baseline.events`, stages 28–39: fixture port 54895 closes; the close and drop fail; its endpoint survives; the next fixture publishes port 54898; selection still returns port 54895.

A correlation-group-only exploratory run passed the spawn assertions but failed the separate `reader_recovers_after_malformed_answers` buffered variant with connection refused. Its selected validation endpoint was also stale. This is recorded separately in `reduced-baseline.*`; it is not counted as a correlated-spawn batch failure and was not repaired.

## Smallest next repair

A bounded follow-up could:

1. Make the close attempt in `remote_drop_connection_locked/1` tolerate both ordinary failure and ordinary exceptions, allowing queue and pending-event cleanup to run. Keep the change local rather than changing all uses of `best_effort/1`.
2. Make fixture endpoint and diagnostic removal unconditional with nested cleanup, even if connection disposal fails or throws. Apply the same pattern to the adjacent mock endpoint fixtures where appropriate.
3. Add a deterministic regression for a failing close and rerun the reduced selections and full T4, retaining existing assertions/timeouts.

A fixture-only repair would prevent cross-test contamination but would leave the runtime's skipped queue cleanup unresolved. No broader reader ownership, connection replacement, shutdown policy or transport protocol change is justified by this batch alone.

## Files and reproduction

- `run.py`: initial six-run prefix comparison; refuses to overwrite its disposable snapshots.
- `results.json`, `snapshots.json`: commands, exits, durations, exact hashes and snapshot paths.
- `diagnostics-prefix.pl`: exact initial diagnostic test file used by the six fixed runs; hash matches `snapshots.json`.
- Current `tests/tiers/node/toplevel_correlation_transport_tests.pl`: opt-in stage diagnostics plus explicit cleanup success/failure/exception events. Enable with `WP_SPAWN_TEST_DIAGNOSTICS=1`; use `WP_SPAWN_TEST_LOG` for a separate event file so passing-test output capture cannot hide evidence.
- `cleanup-results.json`: follow-up prefix commands, using library `prolog_trace` fail-port logging.
- `fail-port-command.json`: command whose fail-port conditions write directly to the diagnostic event file.
- `reduce.py`, `pair-results.json`: reduced fixed comparisons, commands and outcomes.
- `before.json`, `after.json`: runtime/installed-binary hashes and live node process commands.
- `test-at-start.pl`: original test file, before instrumentation.

The fail-port trace wraps predicates in the disposable test process for observation only; it does not edit runtime sources. Event snapshots are observational and not atomic. Diagnostic logging uses a test-only mutex and can affect scheduling.

## Scope preserved

The complete test assertion section has the same SHA-256 as before this batch. No assertion or timeout was changed. Runtime and web source hashes match the start-of-investigation state, including the previously pending asset edits. Installed binary hashes and n3/n5 process identities/commands are unchanged. No nodes were restarted, engines installed, commits created or pushes made.
