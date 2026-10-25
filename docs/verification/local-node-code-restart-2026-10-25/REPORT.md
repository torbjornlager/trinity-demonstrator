# Controlled n3/n5 node-code restart — 25 October 2026

Both public local nodes now run the computed-answer cycle repair:

- n3: <http://localhost:3053/portal>, native SWI; PID 91992.
- n5: <http://localhost:3060/portal>, native Trealla backend 3062; PID 91435.
- n5 frontend: PID 91509. The auxiliary Trealla listener on 3061, PID 97669,
  was left unchanged and is not the updated public n5 endpoint.

## What changed

The node processes were restarted with frozen source snapshots of the tested
working-source candidates. Native SWI starts from `b61270d` plus its early answer
and exception checks. Trealla starts from `9b7c940` plus `answer_terms.pl` and its
PTCP/HTTP guards. [Active-source hashes](active-source-record.json) match the
working runtime files. Tests/docs are not required runtime overlays.

The engine targets, binary hashes and versions are unchanged: the previously
verified SWI 10.1.18 prefix with its existing core/HTTP patches, and unmodified
Trealla v3.14.10 with matching libraries. No installation or engine update occurred.
The demonstrator dependency pin and its default pinned-startup policy are unchanged.

n3's durable local launcher now explicitly loads its frozen native package rather
than invoking the demonstrator's strict pinned loader. The checkout has advanced
beyond that pin; silently relaxing its validator would be inappropriate. The
local launcher retains the demonstrator asset root and the existing assembled
WASM payload directory, keeping browser runtime files unchanged.

Source snapshots and original launcher copies are in:

```
~/.local/share/trinity-local-nodes/code-restart-2026-10-25/
```

The active entry points remain `~/.local/share/trinity-local-nodes/n3/start.sh`
and `~/.local/share/trinity-local-nodes/n5/start.sh`. They select the frozen sources,
so subsequent working-tree edits do not silently change this deployment.

## Startup details and recovery

Before stopping either backend, temporary-port preflights exercised its existing
startup/shared DB settings and confirmed cyclic-answer rejection. n3's final
Admin configuration and n5's final node information match their saved pre-restart
values exactly. Thus profile, blacklist sandbox, auth settings, origins, shared
DBs, tutorial sections, advertised URLs and n3 resident-service configuration
remain as before. Process identifiers naturally change.

The statechart smoke exposed an important launcher prerequisite: explicitly
preloading `library(sgml)` and `library(option)`, as the verified disposable
fixtures do. Without it, XML startup stalled. A separate temporary-port
[preload check](xml-preload-preflight.json) succeeded before n3 was restarted
again with those preloads. The final statechart/monitor smoke passes. No runtime
Prolog source was changed during this restart.

The old n5 frontend process still listened on 3060 but returned empty replies,
and its `/tmp/web-prolog-local-ui/n5_frontend.py` source had disappeared. It was
replaced after temporary-port verification by a durable
`~/.local/share/trinity-local-nodes/n5/frontend.py`. This restores the established
asset/API split: UI assets from n3, Trealla execution on 3062. The WebSocket path
relays bytes; version, health and admin API routes target the Trealla backend.
This is a reconstruction based on the existing acceptance UI proxy, not a claim
that the missing file was recovered verbatim. [Frontend record](frontend-restart.json).

Original launchers/logs were saved. Clean pre-repair HEAD source snapshots and
same-engine rollback launchers are retained as `n3-rollback/start.sh` and
`n5-rollback/start.sh` under the batch directory. Stop the currently recorded
backend before launching a rollback; do not start a second listener. These are
known source baselines, not bit-identical images of modules loaded by the old
long-running processes. The previous older-engine rollback files remain intact.
The restored n5 frontend can remain running with the baseline Trealla backend.

## Verification

All **29 public smoke checks** pass; [checks](checks.json), [answers](smoke.json).
They exercise:

- both public portal URLs and their actual runtime implementation properties;
- computed cycle rejection, and finite answers after internal cyclic computation;
- native SWI cyclic-exception rejection;
- the existing shared DB printer-authorization example on both nodes;
- WebSocket sessions, synchronous toplevel paging and explicit cleanup;
- text-source statechart startup, normal halt and termination-monitor delivery;
- RPC paging, promise timeout callback/retry with shared variables, and promise
  cycle rejection in all four native caller/peer combinations.

The WebSocket smoke acknowledges advertised I/O requests and explicitly halts
its own toplevels. Statechart checks require the existing native `true` halt
acknowledgement and consume the matching child's termination. Early fixture
expectations using `mortal/1` on n5 and the browser-only `stopped` acknowledgement
were corrected to use the nodes' configured shared DB and native semantics;
no node source or assertions in existing regression suites were changed.

Trealla's previously recorded cyclic-exception engine limitation remains open;
this restart does not claim to fix it. No browser/GNU runtime update, full-suite
rerun, repository pin change, commit or push was performed in this batch.

[Before](before.json), [after engine record](after.json), [restart record](restart.json)
and [active source record](active-source-record.json) retain configuration,
commands, engine hashes, source hashes and process provenance. The active source
and same-engine rollback entries reside in durable user-local storage, not `/tmp`.
