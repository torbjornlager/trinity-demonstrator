# SWI-WASM statechart monitor repair — 26 October 2026

Both browser adapters now deliver notifications that match the original exact
`down(P,P,true)` receive pattern after statechart halt. The repair is local
commit **f0783fb4b66fa55ed39774fe0666ada4c8d108fe** and is served by the
commit-pinned demonstrator. It has not been pushed. Existing browser pages need
a refresh to load the repaired adapter.

The preceding [investigation](../statechart-monitor-investigation-2026-10-26/REPORT.md)
retains the failing observations and diagnosis. This batch fixes those adapters;
it does not patch the SWI-WASM engine or change a native runtime.

## Changes

- Local Worker-backed statechart result decoders in both runtimes normalize the
  coordinator's decimal worker key through `canonical_pid/2`. The public pid is
  `Id@localhost`, as for ordinary actors, and spawn monitoring uses that complete
  pid as its reference. Remote creation and global `down/3` serialization are
  unchanged.
- The main-thread primary chart retains the `statechart` singleton pid. Startup
  publishes its actual live state before installing `monitor(true)`, for both
  named and unnamed charts. An explicit monitor in the same query no longer
  receives a false `no_process` notification.
- A shared local-chart stop boundary marks completion and retires only the
  singleton's monitor records before delivering `down/3` with normal reason
  `true`. Repeated halt/status synchronization cannot duplicate notifications.
  Normal completion during startup is retained for late monitor installation,
  consistent with existing Worker completion handling.
- Main-thread chart sends and queued chart events synchronize lifecycle status
  after processing the event. Query-end status synchronization handles direct
  interpreter stops. These boundaries preserve unrelated monitor records and
  existing chart name cleanup.
- The relevant status query now tests the API result's `success` field.
  `query('fail').once()` returns `{success:false}`; treating that object as a
  Boolean had incorrectly marked stopped charts as running. This is an adapter
  API-use correction, not an upstream engine bug.

The browser runtime README records the engine pin and monitor boundaries.
The shared language API and book examples are unchanged. Source ordering,
URI origin restrictions, remote protocols, native pid serialization and native
runtime selections are unchanged. The main-thread secondary-chart halt dispatcher
has not been expanded; the secondary Worker regression uses existing `exit/2`.

## Regression tests

`tests/wasm/swi_wasm_contracts.js` adds two real-engine/real-coordinator scenarios:
`statechart_monitors_worker` and `statechart_monitors_main`, with **29 assertions**
in total. Coverage includes:

- Text and URI chart sources, named and unnamed startup, exact spawn-time pid
  and reference delivery, and no duplicate public notification.
- Same-query explicit monitor installation; `monitor(false)`; explicit
  demonitor with flush; and an unrelated ordinary actor monitor surviving chart
  retirement and delivering its original exact reference.
- Main-thread repeated halt, event-driven final-state completion, completion at
  initial startup, secondary Worker pid normalization, and direct interpreter
  stop followed by repeated host status synchronization.

Worker source replies in the wrapper fixture now use the real coordinator's
bare decimal key, so mocks cannot conceal the normalization bug. The existing
main routing assertion now requires the complete canonical worker pid and
reference, preserving its source, routing and option assertions. The remaining
pre-existing assertion count is unchanged: **2,751 + 29 = 2,780**.

The new negative receive assertions explicitly use `on_timeout(fail)`: a timeout
with its default successful callback would not establish absence of a duplicate.
XML fixtures use SXML's actual `<go on="..." to="..."/>` syntax. Neither correction
changes runtime receive semantics or weakens the exact notification assertions.

## Verification

The unchanged full WASM tier passed on the working tree and again on a frozen
separate source export:

```
python3 tools/ci_timeout.py 360 -- bash tools/test.sh WASM
```

Both runs completed with exit **0**, **2,780** semantic assertion lines and
`all scenarios passed`. The authoritative frozen run took **184.700 seconds**.
It used the verified SWI-WASM 10.1.19 bundle, separate official Node 22.23.4,
and separate native SWI 10.1.19 for the native shared-statechart portion, with
`WP_NATIVE_MODE=legacy`. No assertions or established timeouts were relaxed.

[Working-tree log](WASM.log), [working-tree result](wasm-results.json),
[frozen log](WASM-frozen.log), [frozen result](frozen-results.json).
The frozen export is based on engine-adoption commit `0064d8d` plus exactly the
four recorded changed files. [Source hashes](provenance.json), [patch](source.patch).
The final repair commit contains those same runtime/test/documentation bytes.

Five fresh-process runs per new scenario also passed: **10/10 focused runs**.
See [batch results](focused-batch.json) and the scenario/iteration logs. These
repetitions check asynchronous monitor delivery without changing sleeps or waits;
they are not a proof of race freedom.

## Browser verification

An isolated portal served the frozen repaired frontend with the unchanged
selected browser Prolog payload. Its native HTTP fixture used the frozen native
source `abbc56f3d5104bd6d40d2ed5f99fe6199d75c4a8` and existing selected native
engine, without reconfiguring n3/n5.

All **16** public UI assertions passed: six Worker and ten main-thread. They
include the original exact notification, named startup, simultaneous spawn and
explicit references, unrelated actor delivery, disabled monitoring, natural and
immediate completion; main mode additionally checks repeated halt, a secondary
Worker, and direct-stop synchronization. The direct-stop query deliberately
finishes before the receive query so it exercises host query-end synchronization.
Same-query event-driven completion uses `P ! finish` and is tested separately.

[UI goals/results](ui-results.json), [complete evidence](ui-evidence.json.gz),
[Worker screenshot](worker-ui.png), [main screenshot](main-ui.png),
[temporary node](ui/ui-node.json), [stopped fixture](ui/ui-node-stopped.json).

After publication, fresh sessions on the **live portal** reran the original
exact receive and the explicit/unrelated-monitor assertion in both modes:
**4/4 passed**. [Live results](live-ui-results.json),
[complete live evidence](live-ui-evidence.json.gz),
[live Worker screenshot](live-worker-ui.png), [live main screenshot](live-main-ui.png).
The user's original main-thread preference was restored; temporary tabs closed.
CUA used public UI actions and accessibility observations, not runtime evaluation.

## Publication, preservation and rollback

The served asset commit advanced from `0064d8d` to `f0783fb` without restarting
any node. Byte comparisons through both n3 and n5's frontend confirm the repaired
HTML and Worker script. The commit guard and native setup validation passed;
see [publication](update.json). The SWI-WASM engine remains the already adopted
10.1.19 bundle; the six-file browser Prolog payload is unchanged.

[Preservation](preservation.json) confirms unchanged n3/n5/auxiliary process
identities and start times, native engine hashes, native/Trealla source
selections, and engine bundle hash. No native source, installed engine, book
example or unrelated runtime was changed.

The prior adapter selection and rollback script are retained at:

```
~/.local/share/trinity-local-nodes/statechart-monitor-rollback-2026-10-26/
```

If needed, execute its deployed `rollback.py`; a review copy is [here](rollback.py).
It restores the prior committed adapters while retaining the new engine, refuses
rollback across a later asset/native selection, and validates the guard. The
serving clone retains `refs/rollback/statechart-monitor-2026-10-26`. Rollback was
prepared, not executed after successful verification.

To repeat focused checks, run either new scenario with Node 22; the full-tier
command above preserves the established watchdog. For UI reproduction, use the
goals in `ui-results.json` on a fresh portal page in the indicated mode.
`verify_evidence.py` audits saved results without starting a runtime. This is
local acceptance; no hosted CI result is claimed before push.
