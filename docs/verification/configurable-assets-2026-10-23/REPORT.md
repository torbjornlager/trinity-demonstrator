# Configurable demonstrator assets: first extraction batch

23 October 2026. Base revision is recorded in before.json.

## Changes

- Added the ownership/dependency map at `docs/SWI_NODE_EXTRACTION_MAP.md`, including
  the remaining statechart-helper, WASM, mixed-test, packaging/history and
  deployment dependencies that must be resolved before physical extraction.
- Added node-layer `node_assets.pl` and delegated the existing fixed HTTP page,
  vendor, image, example and WASM source lookups to it. Administration HTML/CSS
  uses the same resolver. Existing routes and handler behavior are retained.
- Added process-wide settings `node_assets:root` and
  `node_assets:wasm_directory`, defaulting from `WP_ASSET_ROOT` and
  `WP_WASM_SOURCE_DIR`. Empty defaults preserve the old layout. An explicit root
  supplies `web/`, `img/`, `examples/` and, absent a WASM override,
  `prolog/web_prolog/wasm/`. Explicit locations do not fall back to the checkout.
- Documented operator configuration in the runtime README. No language predicate,
  node startup option, per-port configuration or live administration setting was
  added. The runtime-owned DTD and lower-layer local example helper are unchanged.
- Added six node asset regression tests and included them in T4. The existing
  automatic node-layer classification recognizes the new module; layering rules
  and lint code were not changed.

No source files or repositories were moved. Shared manual, tutorial/example
content, browser runtime code, engine binaries and n3/n5 configuration are unchanged.

## Verification results

All processes used the separate PCRE-enabled SWI build containing Jan's fix:

`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl`

| Check | Result |
| --- | --- |
| Six new asset regressions | pass |
| LINT | pass; 536 dependency edges checked |
| Fresh-process environment configuration from a foreign CWD | pass |
| Full WASM tier | pass, exit 0 |
| Full T4, initial run | **exit 1**, two transport/lifecycle test failures; asset tests pass |
| Two affected test selections, ten fresh processes against each version | all 20 invocations pass |
| Full T4 on committed baseline exported to a disposable directory | pass, exit 0; 994 reported test cases |
| Full T4 repeat on changed checkout | **exit 1**, correlated-spawn test fails again; asset tests pass; 1,000 reported test cases |

The new HTTP checks use temporary fixture trees and ephemeral HTTP listeners,
not n3/n5. They verify 23 page/asset URL mappings, all six allowlisted `/wasm/`
URLs, MIME/cache behavior, `/examples_index` links, explicit WASM override
precedence, missing-file non-fallback, traversal/absolute-path rejection,
WASM allowlisting, and legacy path/CWD behavior. The same dispatcher failure
mapping currently yields HTTP 500 for missing files or failed prefix handlers;
this batch preserves that mapping rather than introducing a new 404 policy.

The environment probe launches the same separate SWI executable with both
operator environment variables set, from a temporary unrelated working
folder. It confirms root and WASM override resolution independently of CWD.

## Full-tier transport diagnostics remain unresolved

The initial T4 failures were:

1. `toplevel_correlation_transport:matching_startup_failure_and_legacy_fallback`,
   correlated mode. It received `remote_spawn_failed(connection_closed)` with
   `socket_error(econnrefused,'Connection refused')` rather than the expected
   `remote_spawn_failed("startup rejected")`.
2. `cross_node_lifecycle:explicit_monitor_2_carries_user_ref`. Its selected down
   notification carried a different pid/reference than the assertion expected.

The complete repeat reproduces the first failure; the second passes. Both
selected cases pass in ten fresh-process controls per source version. The
committed baseline's full T4 passes once. The correlated-spawn failure occurs
before the new asset-test group executes. None of the transport implementations,
assertions or timeout budgets was edited.

This evidence does not establish a cause or prove the full-tier failure is
pre-existing. The full T4 tier is **not green** for this batch. No transport
repair, test weakening or repeated-run pass was used to erase the failed runs.
The focused asset and browser regressions support the path configuration seam;
the full-tier interaction needs a separate bounded investigation before a
blanket acceptance claim.

## Evidence and reproduction

- `run.py`, `results.json`, `focused.log`, `lint.log`, `t4.log`, `wasm.log`:
  original focused/lint/T4/WASM commands, durations and individual exit codes.
- `environment.json`: exact fresh-process configuration probe and success marker.
- `transport-controls.py`, `transport-control-results.json`, per-trial logs,
  `t4-baseline.log` and `t4-repeat.log`: bounded comparison. Baseline source is
  `git archive HEAD` at the before.json revision; the temporary checkout and
  archive are removed when the runner finishes. It has no .git metadata.
- `before.json`, `provenance.json`: base revision, hashes and node preservation.

From this repository:

```sh
python3 docs/verification/configurable-assets-2026-10-23/run.py
python3 docs/verification/configurable-assets-2026-10-23/transport-controls.py
```

The launchers are diagnostic collectors: inspect each recorded subprocess exit
code, not just the launcher's own status. They use external process-group
watchdogs and preserve failed assertions in their logs. The WASM tier uses the
bundled Node executable explicitly; no installed executable is replaced.
Copy the evidence directory before rerunning: the launchers overwrite results
and logs. The initial transport-control launcher encountered an unsupported
Python 3.9 tarfile filter argument before running tests; it was corrected to use
system tar on the local committed Git archive. Those setup attempts are not
counted as test outcomes.

No graphical browser UI check or new cross-runtime interoperability batch was
run. This is a path/configuration preparation batch, not an installed-runtime
upgrade or completed repository extraction.
