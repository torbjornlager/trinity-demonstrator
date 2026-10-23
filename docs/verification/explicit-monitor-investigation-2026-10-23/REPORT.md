# Explicit monitor notification investigation — 2026-10-23

## Finding

The mismatched notification can be traced to the immediately preceding `down_event_preserves_custom_exit_reason` fixture. It is a second copy of that fixture's termination event, not the explicit monitor's notification with a corrupted reference.

These integration fixtures host their server and client in the same SWI process. As documented by `multi_node_harness.pl`, actor monitor tables are shared. The server actor's ordinary `actors:stop/2` cleanup sees the client's monitor row and sends a notification directly to the test actor. It also notifies its server-side monitor target. That target relays a down frame over WebSocket; the client's controller monitor table then delivers a second notification to the same test actor.

The first copy satisfies the originating fixture's receive. The second copy can arrive after that fixture ends and after the next test's zero-time mailbox flush. `explicit_monitor_2_carries_user_ref` then accepts it through its intentionally broad `down(P,DownRef,_)` receive pattern and fails the unchanged pid and reference assertions.

This is a shared-process harness/fixture-isolation problem demonstrated by the traces. It is not evidence that explicit `monitor/2` changes its reference in transit. The separate-process controls did not exhibit the duplicate; those bounded observations are not a universal proof of exactly-once delivery in every deployment.

## Evidence and bounded results

| Batch | Original explicit-monitor assertion | Overall outcome |
| --- | --- | --- |
| Ten fresh lifecycle prefixes | 10 pass | 10 pass |
| Ten fresh isolated controls | 10 pass | 10 pass |
| Three T4-context prefixes, wrappers enabled only for lifecycle tests | 3 pass | 2 pass; one earlier supervisor-test failure |
| Three neighbouring-fixture selections | 3 pass | 3 pass |
| Three additional isolated controls | 3 pass | 3 pass |
| Three controlled after-flush schedules | 3 fail as expected | Exact historical mismatch reproduced |
| Three real separate-process remote-node controls | Not the original assertion | One matching down each; no second copy during 0.2-second poll |

The uncontrolled diagnostic runs did not reproduce the target assertion failure. Logging changes scheduling, so this is not evidence that the original intermittent failure disappeared. They did repeatedly record both copies and the flush consuming the second copy. The controlled schedule establishes the causal interleaving without changing the original receive pattern, assertions or five-second timeout.

`scoped-context-03.log` has one failure in `supervisor_restart:group_monitor_failure_reclaims_live_provisional_replacements`, before lifecycle wrappers are enabled. Its explicit-monitor test passed. No repair or attribution of that separate failure is attempted here.

### Exact fixture attribution

The exploratory `scheduled.events` gives a complete small trace:

- Stages 3–5: the custom-exit fixture starts port 54850 and spawns pid `7721551799@'http://localhost:54850'`.
- Stages 9–11: local actor cleanup delivers its pid-as-reference notification, consumed by the custom-exit fixture.
- Stages 12–14: its wire copy arrives; a test-only coordinator holds that copy before controller delivery.
- Stages 16–19: the next test completes its ordinary flush and enters its fixture; the coordinator releases the held copy.
- Stages 21–22: the WebSocket reader delivers the old custom-reason notification to the test actor.
- Stages 23–26: the new fixture starts port 54865 and registers pid `8252440831@'http://localhost:54865'` with explicit reference `5451857728`.
- Stage 27: its unchanged receive selects the old pid/reference and fails both identity assertions.

The formal repetitions in `schedule-01.events` through `schedule-03.events` reproduce the same sequence with freshly allocated ports, pids and references. Exit 1 is expected for these negative controls. No `control_hold_expired` event occurs. The coordinator's additional two-second guard is separate from, and does not alter, any existing test timeout. Scheduling control is off unless explicitly started.

`separate-process.pl` starts temporary remote SWI peers using the same separate executable, calls only public spawn/exit/receive interfaces for the observation, and stops those peers afterward. It does not use or restart n3/n5. All three observations in `separate-process.log` show `Extra=none` after the expected notification.

## Instrumentation and limitations

Only `tests/tiers/node/cross_node_lifecycle_tests.plt` changed outside this evidence directory. Diagnostics are opt-in via `WP_LIFECYCLE_DIAGNOSTICS=1` and write to `WP_LIFECYCLE_LOG`. They label fixture entry/start/teardown, observe spawned pids and explicit references, record message selection and complete down deliveries, and identify local actor-stop versus remote wire/connection-close paths. Temporary observational wrappers are installed by the diagnostic driver, not by ordinary test loading.

The initial wrapper prototype observed `stop/1`; the actual cleanup predicate is `stop/2`. Initial delivery events therefore label that path `other`; the later prototype explicitly identifies `actor_stop(Pid,Parent)`. `diagnostics-v1.plt` and `diagnostics-v2.plt` preserve those versions. The optional coordinator was added while the scoped batch was in progress; it was not started in those ordinary runs, so their wire deliveries were not held. The current file includes it for reproducibility.

One exploratory extended batch installed wrappers before the entire T4 prefix. This interfered with earlier supervisor fault-injection tests (18 other-test failures in `t4-context-01.log`), so the batch was stopped during its second context run. Those results are excluded from the table. `extended-aborted.txt` records this. `scoped.py` subsequently runs earlier units without wrappers and enables observation only for the lifecycle selections. Do not interpret the exploratory failures as production regressions.

Normal-mode neighbouring tests also pass with diagnostics off (`normal-mode.log`). The final diagnostics logger treats logging failure as observational, preserving test success/failure.

## Smallest next repair

Repair ownership at the originating fixture boundary: finish or retire that fixture's own monitor-delivery paths and drain only its pid/reference notifications before it returns. Keep the following test's broad receive and identity assertions as a contamination detector. Add the controlled late-wire interleaving as a regression for that cleanup.

Do not just enlarge the zero-time flush, weaken the identity assertions, discard arbitrary `down/3` messages, or globally change monitor delivery to compensate for shared tables. Merely matching the current pid would hide the leftover notification. Any implementation must account for a wire delivery already in flight; a zero-time poll alone is not a barrier. A more faithful separate-process fixture is an alternative if narrow shared-harness cleanup proves awkward, but need not be the first repair.

No fixture repair or runtime repair was made in this investigation.

## Reproduction and preservation

- `run.py`, `results.json`: ten prefix/isolated comparisons with the initial diagnostic version.
- `scoped.py`, `scoped-results.json`: T4-context, neighbouring and isolated fixed batches with lifecycle-scoped wrappers.
- `schedule.py`, `schedule-results.json`: three intentionally failing after-flush scheduling controls.
- `separate-process.pl`, `separate-process.log`: actual process-isolation controls.
- `extended.py`, `extended-results.json`, `extended-aborted.txt`: excluded exploratory broad-wrapper batch.
- `test-at-start.plt`: original fixture tests; `diagnostics-v1.plt` and `diagnostics-v2.plt`: intermediate diagnostic versions.
- `before.json`, `preservation.json`: source/binary/process checks and exact normalized test-body hashes.

The test bodies from the first original test through end-of-file are byte-identical after removing only the new fixture diagnostic labels. Thus all original receive patterns, assertions, timeout options and cleanup bodies remain intact. The existing mailbox flush gained observations only; it still uses the original zero-time receive and recursion.

All runtime source hashes, installed engine hashes and n3/n5 process commands/identities match the start. Testing used the separate PCRE-enabled SWI build containing Jan's fix, not an installed engine. No node restart, installation, commit or push was performed.
