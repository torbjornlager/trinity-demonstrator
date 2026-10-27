# Native SWI maintenance

The native implementation is maintained only in
[`swi-prolog-node`](https://github.com/torbjornlager/swi-prolog-node).
The demonstrator consumes the exact commit recorded in
[`dependencies/swi-prolog-node.json`](../dependencies/swi-prolog-node.json).
The native pack remains `web_prolog`; public predicates and URLs are unchanged.

## Ownership

Native actors, isolation, behaviours, distribution, RPC, server policy, native
administration, the DTD, default database and shared SXML schema belong in the
native repository with their tests. This repository owns the portal, tutorials,
shared manual, examples, browser JavaScript, five browser-only Prolog modules,
application services and consumer integration tests. Do not mirror native fixes
or a second SXML schema here. The former native copy and native pack metadata
have been removed; `WP_NATIVE_MODE=legacy` is rejected.

## Updating the dependency

1. Implement and test native changes in `swi-prolog-node`, and commit them there.
2. Review the candidate and update the demonstrator manifest to its full commit
   SHA. The checkout used for testing must have that exact HEAD and clean runtime
   and package files. Do not substitute a floating branch or local copy.
3. Run `tools/ci_pinned_swi.py` with a fresh output directory. It runs the native
   package tests, external-asset integration, the demonstrator's retained tests,
   startup/pin/packaging regressions, module-origin checks and browser checks.
4. Rerun `tools/setup_swi.py` after changing the pin or browser Prolog sources.
   It validates the package and assembles browser payloads using its schema.
5. Commit the pin, consumer changes and verification record together. Publish
   the native commit before using the pin from another computer or in CI.

```sh
python3 tools/ci_pinned_swi.py \
  --native-root /path/to/pinned/swi-prolog-node \
  --swipl /path/to/verified/swipl \
  --output /fresh/path/pinned-swi-results
python3 tools/setup_swi.py --native-root /path/to/pinned/swi-prolog-node
```

The test runner configures lower-layer imports without preloading the full node.
Missing setup, wrong pins and dirty runtime or assembled payloads fail closed.
Restoring a reviewed older pin and rerunning setup selects that source for future
startup; it does not change already-running processes.

## CI and deployment

Both automatic CI jobs use the same pinned dependency. A private repository
requires the existing `SWI_NODE_READ_TOKEN` read credential; a failed checkout
fails the job. Container builds fetch that same pin and may receive the read
credential through an optional BuildKit `github_token` secret. See the
[deployment guide](../Deployment/README.md#native-dependency-in-container-builds).
No credential is provisioned or repository visibility changed by this migration.

Restarting live nodes, switching their frozen deployment checkouts, installing
engines and deploying images remain separate operations. Historical verification
records describe the revisions and configurations tested at the time; they do
not override these current setup instructions.

## Local character-list adoption checkpoint (25 October 2026)

The demonstrator pin now selects the committed native answer and term-output
repairs. The authorised local n3/n5 deployment uses detached checkouts of exact
SWI, Trealla and demonstrator commits, including the tested model/Jev application
conversions and private-source shadowing repair. Launchers verify their selected
HEADs and reject dirty runtime/application inputs before startup. Character-list
reading is selected for n3 with `WP_EXPERIMENTAL_TEXT=portable-text-0.2`; Trealla
retains its character-list mode. This local adoption does not change the shared
profile baseline or the SWI package's native-string default.

The [adoption record](verification/committed-adoption-2026-10-25/REPORT.md) records
the exact revisions, checks, durable launcher locations and rollback. Repository
access and remote publication remain separate: these locally committed revisions
must be pushed before a different computer can fetch the new pin. Old snapshots,
launchers and engine installations are retained. Trealla cyclic-exception copying,
supplementary-character JSON escapes and broader migration diagnostics remain
explicit; they are not converted into passing conformance results.
