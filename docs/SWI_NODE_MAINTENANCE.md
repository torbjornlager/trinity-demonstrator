# Native SWI maintenance during extraction

The native implementation is maintained in
[`torbjornlager/swi-prolog-node`](https://github.com/torbjornlager/swi-prolog-node).
The demonstrator consumes an exact commit through
[`dependencies/swi-prolog-node.json`](../dependencies/swi-prolog-node.json).
The pack remains `web_prolog`; repository separation does not rename its public
predicates, library imports or URLs. The native repository currently requires
read access. This guide does not configure credentials or change visibility.

## Where a change belongs

| Change | Primary home | Demonstrator responsibility |
| --- | --- | --- |
| Native actors, isolation, toplevels, behaviours, distribution, RPC, node server, sandbox or native administration backend | `swi-prolog-node`, including native regression tests and runtime documentation | Review the pin update and run consumer integration checks |
| Native pack metadata, DTD, default shared database and native SXML schema | `swi-prolog-node` | Keep packaging and browser/schema equivalence checks aligned |
| Portal, tutorial, examples, shared language manual, browser JavaScript and browser-only Prolog | `trinity-demonstrator` | Maintain their integration tests and existing served URLs |
| Dependency validation, startup selection, asset assembly, CI and deployment integration | `trinity-demonstrator` | Exercise the selected native checkout and retain explicit legacy comparisons |
| Common cross-runtime assertions and coverage | `trinity-conformance` | Keep runtime-specific diagnostics separate from required common assertions |

The five browser-only Prolog files are `shared_db.pl`, `statechart_wasm.pl`,
`statechart_wasm_exec.pl`, `statechart_wasm_model.pl` and
`statechart_wasm_runtime.pl`, currently under `prolog/web_prolog/wasm/` here.
The sixth payload, `sxml_schema.pl`, comes from the selected native checkout.
Assembled payloads are generated copies; fixes belong in their source repository.
The physical shared algorithm regions remain subject to the equivalence guard.

The [shared language manual](../web/manual.html) documents common behaviour and
explicit runtime differences. Runtime READMEs hold implementation details. The
book manuscript is maintained separately; this guide changes neither its claims
nor its examples.

## Retained compatibility copies

`prolog/web_prolog.pl`, native `prolog/web_prolog/*.pl`, native package resources
and their retained tier tests are compatibility copies during extraction. New
native work starts in the native repository with its tests. Do not fix only the
retained tree and assume pinned startup will pick it up.

Automatic CI and existing Dockerfiles still select the retained implementation.
For each native fix, explicitly decide whether those consumers need it. When
they do, mirror the reviewed native change and corresponding regression coverage
in a separately identified compatibility update, then test both paths. Keep
host-specific packaging and browser files in their own ownership boundary; do
not synchronize entire directories blindly. If a fix is intentionally not
mirrored, record that limitation for the legacy consumers. A green pinned run
does not establish that an older retained copy contains the fix.

Do not remove retained sources or tests until their remaining consumers have
migrated. The [extraction map](SWI_NODE_EXTRACTION_MAP.md) records those consumers.
Historical investigation and rehearsal records remain evidence, not instructions
to restore the earlier extraction history or repeat an already completed step.

## Updating the native pin

1. Implement and review the native change in `swi-prolog-node`, including its
   regression tests. Run its standalone native tiers using the verified SWI
   build described in the [demonstrator prerequisites](../README.md#running).
   Commit the candidate so it has a full, reproducible SHA. Make that commit
   available to authorized consumers before requesting a remote checkout test.
2. In the demonstrator, update only the intended manifest fields: normally
   `revision` becomes the candidate's full 40-character SHA. Keep the repository
   URL and pack name unless that is a separately reviewed migration. The native
   checkout used for checks must have exactly that HEAD and unchanged runtime
   and package files. Even a documentation-only native commit changes HEAD and
   therefore needs an explicit pin update if it is to be selected.
3. Run the pinned integration command below with a fresh output directory.
   Review every result, the module-origin audit and unresolved diagnostics. Do
   not weaken assertions or substitute the retained sources to obtain a pass.
   Also run the legacy comparison if retained files or their consumers change.
4. Prepare ordinary local startup with `tools/setup_swi.py` after the pin or
   browser sources change. This validates the selection and assembles payloads;
   it does not restart a node. Unexpected payload drift is an error to
   investigate, not a reason to edit generated files.
5. Review and commit the manifest, relevant consumer changes and verification
   record together. Record any compatibility mirroring decision. Installing an
   engine, restarting a live node or deploying an image remains a separate
   operation requiring its own verification and rollback plan.

The manifest and validator are
[`dependencies/swi-prolog-node.json`](../dependencies/swi-prolog-node.json) and
[`tools/pinned_swi.py`](../tools/pinned_swi.py). There is no floating-branch
fallback or automatic pin advancement. Restoring a previous reviewed manifest
revision and regenerating setup selects that earlier source for future startup;
it does not change code already loaded in a running node.

## Integration checks

From the demonstrator checkout, with Python 3, Git, Node.js and the verified SWI
executable available:

```sh
python3 tools/ci_pinned_swi.py \
  --native-root /path/to/swi-prolog-node \
  --swipl /path/to/verified/swipl \
  --output /fresh/path/pinned-swi-results
```

This is the same orchestration used by the manual pinned CI job. It validates
HEAD, creates isolated setup and browser payloads, checks module origins and
runs native LINT/T0/T1_NATIVE/T2/T3_NATIVE/T4_NATIVE/T5, external-asset T1/T3/T4
integration, startup/pin/runner regressions, equivalence and the full WASM tier.
Native layer tests execute from the dependency's own driver without preloading
the full node. Results and logs remain attributable to each check. A failed or
timed-out check makes the overall run fail while later checks still execute.

For the retained comparison, from this checkout:

```sh
WP_NATIVE_MODE=legacy SWIPL=/path/to/verified/swipl ./tools/test.sh
```

To prepare normal pinned startup after successful review:

```sh
python3 tools/setup_swi.py --native-root /path/to/swi-prolog-node
```

The local integration runner never fetches repositories or provisions access.
GitHub's automatic legacy job remains enabled; the pinned job is opt-in through
**Run workflow → pinned_native**. While the dependency is private, the selected
job requires authorized checkout access and otherwise fails. See the
[CI setup and limitations](../README.md#pinned-native-ci-checks) and
[verification record](verification/swi-pinned-ci-2026-10-24/REPORT.md).

## Work still separate

Deployment packaging is paused until the normal deployment computer is
available. Docker defaults, repository access, installed runtimes, n3/n5 and
retained native files are not migrated by this documentation cleanup. Native
runtime fixes must not be confused with changes to the engine executable itself.

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
