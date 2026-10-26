# SWI-WASM statechart-monitor investigation — 26 October 2026

The missing notification has **two independent adapter causes**, plus a related
main-thread liveness defect. It is not a defect in the new WASM engine. No
adapter source was changed during this investigation.

## Findings confirmed through public interfaces

Six diagnostic probes ran in the actual public portal on an ephemeral loopback
fixture using SWI-WASM 10.1.19. The fixture uses the same unchanged adapters as
the selected engine-only adoption. Full goals are in [probes.json](probes.json),
complete observed UI states in [ui-evidence.json.gz](ui-evidence.json.gz).
The probes assert the observed defects; passing a diagnostic assertion is **not**
a conformance pass or a successful repair.

| Probe | Confirmed observation |
|---|---|
| Worker `monitor(true)` | `P` returned by statechart creation is an integer; delivered `D` equals `canonical_pid(P)`, differs from `P`, and the reference still equals `P`. Reason is `true`. |
| Worker explicit `monitor/2` | The exact new reference is delivered, but the pid still differs from the returned pid in the same way. |
| Main immediate explicit monitor | Starting an unnamed local chart and monitoring it in the same query produces `no_process` while the Prolog chart is running. |
| Main spawn monitor | `monitor(true)` followed by halt produces no matching notification. |
| Main split-query chart start | The local chart is running and exposed as the `statechart` singleton. Completing this query updates host-side liveness. |
| Main later explicit monitor + halt | No premature `no_process` is received, proving liveness now permits monitoring; nevertheless halt produces no notification. The exact probe monitor is then withdrawn with `[flush]`. |

All six observations were confirmed. Source/termination waits were bounded;
main diagnostic observations use 0.2-second waits to distinguish immediate
notifications from their absence. The earlier acceptance failure and old-engine
controls retain their original **two-second** waits and exact patterns. Neither
was relaxed or rewritten as a pass. The two old-engine controls reproduce the
original failure; see [acceptance diagnostic](../wasm-engine-8.2.5-2026-10-26/REPORT.md).

## Worker cause

In `web/swi_wasm_actor_worker.js`, `browser_statechart_spawn_options/2` calls
`statechart_spawn_worker_result/2`. That decoder reads the coordinator's decimal
worker-map key directly into `Pid`. Unlike ordinary `spawn/3`, it does not turn
it into the public `Id@localhost` form.

`install_spawn_monitor/2` correctly preserves the reference it is given: it uses
that returned pid as the spawn-time reference. Later,
`deliverSwiWasmActorDown` in `web/demonstrator.html` qualifies the notification's
first field with `qualifySwiWasmLocalPid`, preserving the reference unchanged.
The result is effectively:

```
returned P = 1234567890
received   = down(1234567890@localhost,1234567890,true)
```

Therefore `down(P,P,_)` cannot match. The original notification was delivered,
not lost. The diagnosis is proved by the public assertions
`D==Canonical,P\==D,R==P,Reason==true,integer(P)` after `canonical_pid(P,Canonical)`.
The same mismatch appears with an explicit reference. UI pid hiding makes the
first fields look equal, so the diagnostic compares terms rather than their
rendered display.

The main-thread adapter contains the same bare-pid decoder for its **secondary
Worker-backed** charts. Its primary local chart is a different, intentional
case and returns the sentinel `statechart`.

## Main-thread cause

The primary local branch of `browser_statechart_spawn_options/2` in
`web/demonstrator.html` does this:

```
statechart_wasm:statechart_start(...),
Pid = statechart,
maybe_register_toplevel_name(...)
```

It never invokes `install_spawn_monitor/2`. The remote and Worker-backed
branches do. Thus a valid `monitor(true)` option is silently omitted for the
main-thread singleton.

There are two further integration gaps:

1. For an unnamed chart, `swiWasmStatechartActive` is normally synchronized only
   after the query finishes, in `syncSwiWasmStatechartStatus`. A same-query
   explicit monitor calls `swiWasmActorPidLive("statechart")` too early and is
   immediately given `no_process`. Merely inserting spawn-monitor installation
   without first publishing accurate liveness would produce the wrong event.
   Named publication also updates this flag, but only after its creation goal
   returns; it is not a general substitute for a start-time liveness boundary.
2. `statechart_halt(statechart,...)` calls `swiWasmNamedChartStopped` after stopping
   the interpreter. That helper only clears the active flag and names. It never
   calls `notifySwiWasmActorMonitors("statechart",...)`. The status-sync path also
   clears names without notifying monitors. An explicit monitor established in
   a later query therefore receives no termination notification either.

The split-query diagnostic establishes this distinction: before halt there is
no `no_process`; after halt there is still no `down`. The exact reference is
cleaned up at the end of that disposable probe.

## Smallest bounded repair to consider

1. Normalize **local Worker-backed statechart results** using the existing public
   pid convention in both result decoders. Keep remote pid decoding and complete
   monitor references unchanged. Do not change global `down/3` serialization.
2. Publish the main-thread chart's actual live state at successful start before
   installing `monitor(true)`, and install that option in the singleton branch.
   Cover named and unnamed starts without replacing their existing startup
   rollback rules.
3. Route the relevant singleton stop transitions through one notification step
   that retires only its monitor records, preserves unrelated monitors, and
   avoids duplicate delivery. Explicit halt must emit the existing normal-exit
   reason `true`. Check direct stop/status-sync paths too so they cannot retain
   stale records or notify a later chart incarnation accidentally.

This is a small adapter integration repair, with no engine patch, wire protocol
change or need to replace main-thread chart execution with Workers. Its exact
scope should preserve the intentional `statechart` singleton and existing
ordinary/remote actor behavior. Secondary-chart halt dispatch and general chart
restart/incarnation design are separate subjects; normalization alone does not
claim to implement missing main-thread secondary-chart halt support.

Regression coverage should retain the original exact `down(P,P,true)` wait;
add explicit references, named/unnamed charts, repeated halt/no duplicate,
monitor(false), unrelated monitors, and same-query liveness. Exercise both
Worker-backed pid decoders. Rerun the full WASM tier and both UI modes before
publishing an adapter repair. The current tests' mocked Worker reply already
includes `@localhost`, whereas the real coordinator returns a decimal key; that
fixture difference is worth covering directly.

The bounded repair is worthwhile because both symptoms break ordinary monitor
usage, and fixes belong at existing startup/stop and pid-conversion boundaries.
There is no evidence here requiring an upstream SWI engine report.

## Preservation and reproduction

The probe fixture was launched by the acceptance batch's `serve_candidate.py`
with a fresh `TEST_WASM_EVIDENCE` directory; see [node record](ui-node.json).
It was stopped and its temporary browser tab closed. The live portal's original
main-thread preference was restored after the separate adoption smoke checks.
[Preservation](preservation.json) records unchanged native engines, processes,
native source selections and adapter sources, with the intentional new bundle
selection recorded separately in the [adoption report](../wasm-engine-adoption-2026-10-26/REPORT.md).

To repeat, start a fresh disposable fixture, select the indicated mode, and run
the saved public goals in order. `main_chart_live` deliberately completes before
`main_stop_no_notify`; merging them would test a different liveness condition.
The Worker probes consume only the chart notifications they create. The
main-thread explicit references are explicitly demonitor-flushed. No user
session, existing monitor or book example is modified.
