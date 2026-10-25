# URI representation audit and repair — 24 October 2026

## Contract

Atoms are the canonical internal representation of URI/path and node-URL text.
Input conversion preserves spelling, Unicode and percent escapes; it does not
add URI syntax canonicalization, origin permissions, new schemes, redirect
rules, file access or relative-resolution behavior. Numbers and arbitrary terms
are not URI text, and unbound destinations/components are not instantiated by
matching a convenience form. Existing source and destination policies remain.

| Runtime | Accepted boundary representations |
|---|---|
| Native SWI | Atoms and SWI string objects. RPC/promise additionally accept Host:Port, checking text host and integer port before formatting. Source URI and node options retain their documented text-only forms. |
| Trealla | Atoms/character lists and RPC/source/explicit-connection code-list text normalize to atoms. The node spawn option retains its existing atom/character-list validator. RPC/promise Host:Port is made explicit and checked; local node/send routing compares the normalized atom so textual localhost works consistently. |
| SWI-WASM Worker and main | URI and node text accepts atoms/SWI strings and normalizes to atoms before the JS bridge. RPC/promise Host:Port is normalized explicitly, not printed as an arbitrary compound. Source URI grouping/order is preserved. |
| GNU ISOBASE | Atom, character-list and code-list URI text remains accepted. Existing Host:Port support remains for destinations and source URIs, with checked, nonbinding host/port components. Every source URI option is representation-checked before source composition; cyclic inputs are rejected. Existing HTTP(S) syntax/address permissions remain. |

This is representation validation, not a complete RFC URI parser. In particular,
port ranges, reachable hosts, absolute/relative paths, localhost resolution and
permitted origins remain governed by existing role-specific policies. The new
helpers do not mutate caller text or rewrite goal/template variables. Only
supported destination shorthand accepts a compound; arbitrary terms are not
converted with formatting. Pid node components should be atoms in portable code.

## Implementation

Native source_utils:uri_atom/2 and pid_utils:node_url_atom/2 now give explicit
errors for unsupported/pending representations instead of silent failure.
resolve_rpc_uri/2 only matches Host:Port after confirming the input is nonvar;
it checks components rather than formatting unknown terms. This native-owned
change is mirrored explicitly in the demonstrator's retained legacy tree.

Trealla reuses a checked source_policy:uri_atom/2 before RPC/promise preparation,
source fetching and distribution URL storage. The existing source-policy module
is already loaded by isolation. Qualified helper calls keep that established
loading path rather than adding a new early import that changed user alias
availability. No engine or general module-loader repair is included.

Both generated browser bridges normalize the destination before serializing it,
normalise source URI text before fetching, and normalize node options before
routing. Main/Worker RPC/promise keep their existing transport and promise stores.
GNU only changes the URI representation checks and adds isolated-worker tests;
other option families and transport code are unchanged.

## Verification

- Native SWI: focused URI/Boolean/synchronous groups pass 164 parameterized
  checks; LINT, full T2 and T4_NATIVE (1020 named cases) pass. The new URI
  fixture covers canonical text, explicit errors, zero fetches on invalid
  destination types, Host:Port, live RPC/promise sharing and URI source loading.
- Archived native controls: resolve_rpc_uri(42,_) previously failed silently;
  now it throws type_error(atom_or_string,42). A pending URI previously became
  Host:Port and a formatted URL containing variables; now it raises an
  instantiation error without binding the input. No network operation is used
  by these controls; the temporary archive was removed.
- Trealla: focused canonicalization/local routing, existing synchronous,
  wrapper and RPC-option groups and controlled source-policy group pass.
  Loopback RPC/promise checks exercise atoms, character lists, code lists and
  Host:Port while preserving answer/caller independence (seven requests).
- Both actual SWI-WASM engines under Node pass the new URI scenarios, including
  canonical atom bridge spellings, early-error/no-operation checks and RPC/
  promise results. Full WASM tier and retained-legacy T2/T4_NATIVE pass.
  This is automated engine/harness evidence, not a new browser UI session.
- A separately compiled GNU worker passes 22 URI/zero-request/text-form/
  shorthand/sharing assertions, 41 preceding Boolean assertions and six
  framing/sharing assertions. Its temporary compilation stage was removed;
  the existing query-worker binary was not replaced.
- Disposable native shared fixtures pass all 24 unchanged promise/yield and
  eight HTTP interoperability selections in four directions. All eight raw
  reports pass schema/count validation. No new shared case count is inferred
  from implementation regression tests. GNU shared baseline and full engine
  acceptance suites were not rerun in this batch.

The native loopback fixture initially matched only templates beginning with
pair(; protocol templates are parenthesized, so the corrected fixture matches
the enclosed term. Browser helper-only assertions initially needed explicit
bridge module qualification, and the main mock's operation counter is an object,
not an array. These are new test-fixture corrections, not weakened assertions.

An existing Trealla RPC-option regression caught missing user make_ref/1 after
an added early source-policy import. The archived-source control passes. The
candidate now calls the already-loaded helper qualified; the exact existing
RPC-option test passes again, alongside the final focused/live/source checks.
The development failure, archived control and final logs remain separate.
No independent engine defect or upstream repair is claimed.

## Evidence and preservation

Commands, exits and engine identities are in checks.json. Trealla additionally
records final-checks.json, live request paths and the source-policy/archived
controls. Native before-controls.json identifies its archived baseline. Final
working-tree hashes are in patch-inputs.json; shared provenance records complete
runtime source snapshots. The URI work includes the preceding uncommitted
Boolean source candidates, whose own historical evidence remains untouched.

Shared results are in trinity-conformance/reports/2026-10-24-uri-promise-http/.
Installed executable targets/hashes, the dependency pin and live n3/n5 identities
are checked in preservation.json. Temporary fixtures stopped. No launcher,
installed engine, n3/n5 process, repository access setting, book example or
historical report was changed. Other lifecycle/admission/whitelist findings
remain separate; this is not a general security or URI-policy certification.
