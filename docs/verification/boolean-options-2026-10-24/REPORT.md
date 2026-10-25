# Boolean option audit and repair — 24 October 2026

## Contract and bounded changes

Language Boolean option values are the atoms true and false. Numbers (including
0, 1 and floating variants), strings/character lists, differently cased atoms
and JSON wrapper compounds are rejected. An unbound Boolean value is not bound
to true. Quoted 'true' is the same atom as true, not a string substitute.

| Surface | Audit and repair |
|---|---|
| Native SWI | Spawn link/monitor, toplevel session, statechart trace and RPC/promise once already validate Boolean types. Asynchronous toplevel_call/3 now checks every once occurrence before dispatch, including invalid later duplicates, and leaves pending values unbound on error. |
| Native Trealla | Existing language Boolean validators are strict. Asynchronous toplevel_call/3 now performs the same check before selecting the local or registered remote route, rather than waiting for the receiving actor to reject a value. |
| SWI-WASM Worker and main engine | Existing spawn/wrapper/RPC/promise validators are strict. Both generated Prolog bridges now reject invalid asynchronous toplevel once values before any coordinator operation. |
| GNU ISOBASE | iso_once/1 previously unified a pending value with true, and later once duplicates were not checked. It now uses identity comparisons, rejects pending values with instantiation_error and checks every once occurrence before request preparation. Other option schemas and timeout/source policies are unchanged. |

The first valid scalar setting still wins. Goal/template sharing and ordinary
paging, synchronous waits, source loading and callback semantics are preserved.
This does not add complete asynchronous option validation: the new async check
covers once/1 specifically, not a new catalogue of all accepted options.

The native-owned SWI changes were mirrored explicitly into the demonstrator's
retained legacy source. No dependency pin was promoted. Browser sources remain
demonstrator-owned; GNU and Trealla changes belong to their own repositories.

## Transport distinction

HTTP parameters are textual encodings, and JSON has actual Boolean values. These
must still decode before entering the language API. Native trace endpoints keep
their existing case-folded text and JSON-wrapper decoding; administration field
compatibility remains unchanged. That does not admit trace("true") or
once("true") as language options. Internal browser conversion of encoded Prolog
atoms likewise remains intact.

The transport audit also found two recursive native decoders: HTTP enabled text
could recurse on an already lower-case string, and invalid WebSocket text could
cycle between atom and string forms. They now case-fold once and match directly.
Canonical true/false, actual JSON Boolean wrappers and existing valid textual
forms still decode; numbers and invalid text produce errors without looping.
The separate direct language validators reject JSON wrappers.

## Verification and remaining findings

- Native SWI: 141 focused parameterized checks (new Boolean regressions plus
  existing synchronous checks), LINT, full T2 and final T4_NATIVE pass.
- Archived native source controls: asynchronous once(1) previously returned
  accepted; now it raises type_error(boolean,1). HTTP "true" and WebSocket
  invalid "bogus" previously exceed the 0.2-second control deadline; the
  candidate respectively decodes true or raises domain_error immediately.
- Trealla: Boolean regressions, existing synchronous-wrapper tests and wrapper
  validation checks pass on the separate unmodified v3.14.10 engine/library.
- Browser: new Worker/main Boolean scenarios pass on actual SWI-WASM engines
  under Node, checking rejection before coordinator/RPC/source operations.
  Full WASM tier passes, as do legacy T2 and final legacy T4_NATIVE.
  These are automated engine/harness checks, not a new interactive UI run.
- GNU: a separately compiled query-worker passes 41 Boolean/zero-request/
  precedence/paging/sharing assertions and six existing framing/sharing checks.
  The same Boolean regression fails against a separately compiled archived
  pre-repair rpc.pl at the invalid later once(1) duplicate. Temporary compiler
  output was removed; the existing query-worker binary hash is unchanged.
- Shared toplevel-waits contract: 12/12 on disposable native SWI/Trealla nodes;
  raw report counts/schema validation pass. This pack is unchanged and does not
  acquire extra Boolean case counts from implementation regression tests.

One development native T4 run observed the intermittent
supervisor_restart_ownership:live_group_replacements_remain_reclaimable_after_monitor_failure
failure. Its log and checks are retained separately as *.development.*. No
supervisor assertion, timeout or runtime code was changed; the stable final full
run passes. This does not explain or claim a repair of that intermittent finding.
Other lifecycle, admission and whitelist qualifications remain separate.

An initial new native fixture omitted the statechart module import; the final
fixture imports it explicitly and checks actual Boolean errors. A test invocation
also initially used the wrong Trealla wrapper-test predicate name; the corrected
existing wrapper_option_tests group passes. Neither required changing existing
assertions or timeouts. checks.json records the final commands and exits.

## Evidence and preservation

Per-repository evidence:

- Native SWI: docs/verification/boolean-options-2026-10-24/ — focused/LINT/T2/T4
  logs, archived-source controls, final patch hashes and preservation record.
- Trealla: reproducers/boolean-options-2026-10-24/ — focused, synchronous and
  wrapper logs and commands.
- Demonstrator: docs/verification/boolean-options-2026-10-24/ — complete WASM
  and legacy logs, final legacy T4 check, plus individual new-engine scenarios.
- GNU: isobase/verification/boolean-options-2026-10-24/ — isolated build,
  before-control and regression logs with installed-worker preservation hash.
- Shared suite: trinity-conformance/reports/2026-10-24-boolean-toplevel-waits/ —
  raw public-interface results, provenance, preservation and coverage matrix.

Installed runtimes and their launchers, the demonstrator dependency pin and
live n3/n5 are unchanged. Only disposable processes and temporary build products
were used. No book examples, historical conformance reports, authentication or
repository access settings were changed. The source patches are uncommitted
while tested; patch-inputs.json and fixture source hashes identify the candidates.
