# Shared-process lifecycle fixture cleanup — 2026-10-23

## Outcome

Full T4 passed, exit 0, with 1,004 test declarations including their forall variants (`t4.log`, `results.json`). The focused checks and complete lifecycle group also passed. No runtime source, installed engine, or n3/n5 process was changed.

The repair is confined to `tests/tiers/node/cross_node_lifecycle_tests.plt`. It addresses the shared-process harness's duplicate local/wire termination notifications identified in the preceding investigation. It does not change the language's monitor semantics.

## Fixture ownership and cleanup

Each lifecycle fixture has a private token. Small test helpers call the same public `spawn/3` and `monitor/2` predicates and record monitors explicitly requested by that fixture's caller: watcher, canonical pid and reference. Recording survives ordinary local monitor-row retirement, so cleanup still knows which queued notifications belong to the fixture. The source-shipped `parent_with_remote_child` helper retains its ordinary spawn call.

Before the fixture's server is torn down, cleanup:

1. Acquires `actors_registry`, then `actors_monitor_lifecycle`, matching local retirement and remote delivery lock order.
2. Withdraws only the recorded watcher/pid/reference rows from the local actor table and controller mirror.
3. Releases the locks and drains only that pid/reference's queued or deferred `down/3` messages using zero-time receives.

The locks provide the missing barrier: a delivery already inside the lifecycle transaction finishes before cleanup proceeds; a later wire delivery no longer finds this fixture's watcher. Cleanup does not need to wait for every WebSocket reader to exit. Server monitor targets and other watchers/references remain intact. Cleanup runs through `call_cleanup/2` on success, failure or exception.

This directly manipulates shared tables only inside the test harness. It is deliberately not a runtime workaround or a replacement for public demonitor semantics.

## Regressions

`late_previous_fixture_notification_is_retired` reuses the original custom-exit and explicit-monitor scenarios, including their unchanged broad receive patterns, identity assertions and five-second receive timeouts. The existing test declarations retain their `Result == ok` checks; scenario helpers return that same Result to the declarations.

A separate test-only coordinator holds the custom fixture's wire copy before controller delivery. The fixture waits for this held state before retiring its watcher. The following fixture performs its original mailbox flush, then releases the old wire copy. That copy finishes without notifying the next fixture. The regression checks completion, retirement and absence of a late old-pid notification. Its own bounded coordinator guards are two seconds; existing test timeouts are unchanged. The coordinator installs only its narrow wire-delivery wrapper for the regression, with no global diagnostic wrappers enabled during full T4.

`fixture_cleanup_preserves_other_watchers_and_messages` verifies that cleanup preserves:

- Another watcher's local and controller rows, even with the same pid/reference.
- A queued notification for another pid and reference.
- A queued notification for the same pid with another reference.
- A queued notification for another pid with the same reference.

It also verifies that the owned pending notification and owned table entries are removed. The two-second coordinator wait and the new regression's ten-second outer bound are new regression safeguards, not increases to existing tests.

## Validation

- Focused original scenarios and new regressions: pass (`focused.log`, final forms in `final-focused.log`).
- Complete lifecycle group: pass (`lifecycle-group.log`). The final full T4 additionally exercises the stronger unrelated-message cases added to the new scoping regression.
- Deterministic red control: disable fixture monitor cleanup in a disposable source snapshot and run the new controlled regression. It fails the original pid/reference assertions with the preceding fixture's pid (`red-control.log`, `red-control.events`). Thus the regression detects the identified defect rather than merely checking its bookkeeping.
- Full T4 on the final test-file hash: pass, 1,004 declarations (`t4.log`, `results.json`).
- `git diff --check`: pass.

The earlier intermittent callback stall and supervisor-test failures were not reproduced in this final T4 run and are not claimed fixed by this test-only change.

## Reproduction and preservation

`run.py` records the red-control, final-focused and full T4 commands, durations, exits and test-file hashes in `results.json`. Its private source snapshot lives under `~/.local/share/trinity-runtime-tests/lifecycle-fixture-cleanup-2026-10-23`; the script refuses to overwrite an existing directory. `test-before-repair.plt` preserves the preceding diagnostic fixture version.

Testing used the separate PCRE-enabled SWI executable containing Jan's fix; executable path/hash and preservation checks are in `preservation.json`. Existing assertion lines, receive-pattern lines and timeout values were retained. All runtime source and installed binary hashes match `before.json`; n3/n5 process identities and commands also match. No installation, restart, commit or push was performed.
