# Native SWI split-layout verification — 2026-10-23

## Outcome

The native package loads and serves `/healthz` and JSON `/call` from a foreign working directory with no demonstrator frontend directories present. Native selections of T0–T4 and external integration selections of T1/T3/T4 have successful runs. The original full T4 also passes all 1,004 declarations, preserving its original unit order. Two unchanged legacy-layout compatibility tests pass separately in the original colocated checkout.

The headless T4 selection required bounded reruns: its first run completed with a supervisor-test failure; its second stalled at an HTTP callback test and hit an external watchdog; its final fresh run passed all 983 native declarations without code or assertion changes between those runs. These diagnostics are retained and are not claimed fixed by the layout changes.

No physical repository extraction, runtime-source edit, engine installation or live-node restart was performed.

## Changes

- `tests/tiers/test_partition.pl` classifies test ownership explicitly as native, external integration, or legacy-layout compatibility. Unknown units and stale named classifications fail. The original tests remain in their existing modules.
- T1/T3/T4 expose `run_native`, `run_integration` and `run_legacy_layout`; their original `run_tier` uses exactly its original ordered unit list through a shared fact. `tools/test.sh` has opt-in labels for these selections; the default full-tier run does not duplicate them.
- `tests/tiers/test_layout.pl` resolves test-only demonstrator inputs through `WP_ASSET_ROOT`, preserving checkout-relative defaults when unset and importing no runtime node module. This keeps T1/T3 layer-honesty checks meaningful.
- Direct HTML/example reads, the T1 count-server input, T3 example scans/service-request scenarios and T4 service-directory/deployment-overlay data now use that helper. Relative statechart URI tests retain their original URI strings and use the external example root as their working directory. Assertions, test declarations and timeout values are preserved.
- `tools/check_swi_split_layout.py` creates disposable trees, records a hashed manifest, starts only temporary test listeners, and runs the checks. The extraction map and root README document the boundaries and commands.

There are no changes to public URLs, runtime asset/source-loading logic, example files, browser runtimes, the language manual or the book.

## Disposable package and dependency discovery

The recorded work directory is `~/.local/share/trinity-runtime-tests/swi-split-layout-2026-10-23`:

- `native/` contains 147 copied native package/test-support files. It has no `web/`, `img/`, `examples/`, `.git` or symlinks.
- `demonstrator-assets/` contains 133 copied frontend/example/browser payload files and the two existing shared-db overlays used by integration tests. Their contents are unchanged.
- `foreign-cwd/` is used for the headless package/API probe.

The native parser has an existing direct import of **`prolog/web_prolog/wasm/sxml_schema.pl`**. That file is a shared validator, not a browser execution module. The rehearsal therefore retains it at its current native import path and excludes the five browser-only Prolog files. The external browser payload also includes the same byte-identical schema source. This corrects the earlier extraction map's assumption that every file under `wasm/` was browser-only. Shared-schema packaging must remain explicit during actual extraction; no schema relocation or fork was introduced here.

The two legacy tests assert actual files at colocated default paths (`same_file/2` and `exists_file/1`). Their assertions cannot apply to an intentionally asset-free native tree. They remain explicitly selected and exercised in the existing checkout; they were not weakened, conditionalized or silently dropped.

## Coverage and results

The audit compares the exact multiset of loaded test declaration IDs with the union of the three selector outputs. All three tiers pass exhaustive/disjoint coverage checks (`T1-partition-verified.json`, `T3-partition-verified.json`, `T4-partition-verified.json`).

| Tier | Native declarations | External integration declarations | Legacy-layout declarations |
| --- | ---: | ---: | ---: |
| T1 | 65 | 1 | 0 |
| T3 | 293 | 14 | 0 |
| T4 | 983 | 19 | 2 |

Declaration counts retain existing `forall` expansion and condition gates. T3 reports 292 scheduled native declarations because its existing distribution-dependent named-creation condition remains inactive at this lower layer; the declaration and condition are retained.

| Check | Result |
| --- | --- |
| Headless loader and HTTP API, foreign CWD | Pass |
| T0 native, 102 declarations | Pass |
| T1 native / external integration | Pass / pass |
| T2 native, 89 declarations | Pass |
| T3 native / external integration | Pass / pass |
| T4 external integration, 19 declarations | Pass |
| T4 legacy-layout compatibility, 2 declarations | Pass |
| T4 original full selection, 1,004 declarations | Pass |
| T4 headless native final, 983 declarations | Pass |
| Exhaustive/disjoint partition audits | Pass |
| Layering lint, 554 checked edges | Pass |
| Explicit shell label in default layout (`T1_INTEGRATION`) | Pass |
| Shell syntax / diff whitespace | Pass |

### Retained intermittent diagnostics

- `T4-native.log`: first headless native run reached the end with failure in `supervisor_restart:automatic_failure_respects_numeric_and_brutal_shutdown`. Five fresh isolated controls of that unchanged case passed (`supervisor-control-01.log` through `-05.log`). The exact cause was not investigated or repaired here.
- `T4-native-retry.log`: a fresh headless rerun stopped progressing at `node:isobase_yield_timeout_callback_is_sandboxed` and reached the 180-second external watchdog. A stall at that test was also recorded before this batch. Existing test assertions and timeouts were untouched.
- `T4-native-final.log`: the final fresh run on the same disposable native tree and engine passed, exit 0, in 52.854 seconds (`native-final-results.json`).

The initial rehearsal command correctly returned nonzero for the first failure; its records were not overwritten or reclassified as a pass. The successful full original T4 and final headless selection establish successful coverage of every selection, not an assurance that the suite is free of intermittent failures. Do not attribute those failures to extraction or dismiss them as harmless without a separate investigation.

## Evidence and reproduction

`tools/check_swi_split_layout.py` now incorporates the stronger multiset coverage audit used by the follow-up verification. The initial invocation wrote classification/specification exports; those were independently checked and retained as `T*-partition-verified.*` with exact commands in `partition-verification-results.json`.

A fresh run requires a new disposable work directory:

```sh
python3 tools/check_swi_split_layout.py \
  --swipl /path/to/separate/verified/swipl \
  --work-dir /tmp/swi-split-layout-rehearsal \
  --report-dir /tmp/swi-split-layout-results
```

The strengthened headless probe additionally verifies the loaded `node`, `actors`, `isolation` and `sxml_schema` files belong to the disposable native tree. A globally installed pack cannot satisfy this probe accidentally (`headless-source-identity.json`, `headless-source-identity.log`). The rehearsal tool includes this guard for future runs.

The recorded executable is the separate PCRE-enabled SWI build containing Jan's fix; path/hash are in `layout.json`. All subprocesses used that engine. Native runs unset asset overrides; external integration sets both `WP_ASSET_ROOT` and `WP_WASM_SOURCE_DIR` to the external tree. No installed engine was replaced or selected by changing PATH.

Useful records:

- `manifest.json`, `layout.json`, `final-layout.json`: exact paths, roles, hashes and asset-free layout checks at rehearsal completion.
- `results.json`, `runner.log`: initial commands, durations and outcomes, including the original full T4 run.
- `retry-results.json`: five isolated supervisor controls and the timed-out native rerun.
- `native-final-results.json`: successful final native rerun.
- `partition-verification-results.json`, `T*-partition-verified.json`: exact coverage checks and selected declaration IDs/counts.
- `before.json`, `preservation.json`: original source revision/test hashes, unchanged assertion/declaration/timeout checks, unchanged tier-list order, runtime/asset/installed-binary hashes and n3/n5 process identity checks. README/map documentation was updated after the initial package snapshot; runtime and test code in that snapshot retain their recorded hashes.

## Next boundary

The extraction map now distinguishes tested layout boundaries from actual repository work. Still deferred: the lower-layer `interpret_example/1` convenience helper, T5's historical peer/tag materialization, shared-schema publishing ownership, WASM equivalence tooling across repositories, repository/history extraction, pinned native dependency wiring, and Docker/deployment assembly. The shared language manual and book remain untouched.
