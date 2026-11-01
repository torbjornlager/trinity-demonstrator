# Test ownership and tiers

`tools/test.sh` runs the native suite directly from the validated, pinned
`swi-prolog-node` checkout. There are no runtime test copies in this directory.
Every tier uses a fresh SWI-Prolog process with a process-group watchdog. Loading
errors fail the tier before its tests run. A missing tier is an error.

Native processes run from the native checkout, with `WP_ASSET_ROOT` pointing to
this demonstrator and `WP_WASM_SOURCE_DIR` pointing to its assembled browser
payload. The bootstrap configures library lookup without preloading upper layers;
the upstream layer-honesty assertions remain active. Runtime files, test sources,
fixtures and the layering lint must match the dependency pin before execution.
Relative `SWIPL` and `WP_NATIVE_STATE` overrides are resolved before changing
directories, so the native and local tiers use the same executable and setup.

| Selection | Owner and coverage |
|---|---|
| `LINT` | upstream layering lint |
| `TEXT` | upstream portable-text suite and boundary tests |
| `T0` | upstream actors, without higher layers |
| `T1` | upstream isolation and source preparation |
| `T2` | upstream toplevel actors, including cyclic-answer guards |
| `T3` | upstream behaviours, including server-upgrade lifecycle |
| `T4` | upstream native and external-asset integration partitions |
| `DISCOVERY` | demonstrator hub scheduling/latency and browser query round trips |
| `T5` | upstream interop against its checksummed historical-server archive |
| `T1_NATIVE`, `T3_NATIVE`, `T4_NATIVE` | upstream runtime-only partitions |
| `T1_INTEGRATION`, `T3_INTEGRATION`, `T4_INTEGRATION` | upstream external-asset partitions |
| `DEMONSTRATOR` | local consumer contracts against the actual example-service bootstrap |
| `SERVICE_TEXT`, `LINDA`, `MODEL`, `MODEL_SXML`, `JEV` | local application/example tests |
| `WASM` | browser-package tests and demonstrator-owned browser adapters |

With no arguments the runner executes the complete table, using full `T1`, `T3`
and `T4` rather than running their partitions a second time. CI uses the split
partitions for separate logs and runs each native selection only once.

The two upstream `legacy_layout` checks assume assets colocated with the native
runtime. That layout does not apply here. `T4` therefore runs `run_native` and
`run_integration` in separate processes, excluding only those two checks. Both
partitions run even if one fails or times out. Asset relocation tests still
run upstream; demonstrator startup/pin tests check the external-package layout.
The retired `T4_LEGACY_LAYOUT` selection remains an error.

## Consolidation audit

The 57 removed Prolog test/helper files were compared with the pinned upstream
tree before removal. The substantive differences were resolved as follows:

- Runtime import paths and subprocess bootstraps are provided by the shared
  runner. Native-relative paths, including the shared database used by the n5
  overlay test, resolve from the native working directory.
- The exact counter/Linda/pubsub catalogue assertion is retained in
  `tests/demonstrator_integration_tests.pl`. Its fixture imports
  `examples/services/node_resident_services.pl`, rather than maintaining a
  second copy of that example implementation. It tests all three live services
  and the owner-installed Linda client. `LINDA` is also an explicit CI gate.
- Portable-text tests renamed or made unconditional in the demonstrator were
  already covered by upstream's character-list cases. The pinned runtime uses
  that mode by default; the upstream conditions are retained unchanged.
- Local omissions and weaker assertions are replaced by upstream's stronger
  checks: cyclic answers, lifetime context selection, DCG guards, retired source
  options, and server upgrades. The previously missing `portable_text_tests.pl`,
  `portable_text_boundary_tests.pl`, `supervisor_admission_tests.pl`,
  `spawn_source_validation_tests.pl` and `server_upgrade_lifecycle_tests.pl`
  are now reached through their upstream tier entry points.
- T5 uses upstream's checksummed source fixture and its admission tests, replacing
  the demonstrator copy's dependency on a historical Git tag.

Runtime fixes and runtime regression tests belong upstream. Changes to examples,
presenter assets, application services and deployment integration belong here.
Do not restore a copied runtime suite to adapt a demonstrator expectation.

The T4 stall observed during consolidation was traced to an uncollected self-RPC
in `node:isobase_yield_timeout_callback_is_sandboxed`. Its upstream fixture now
uses `setup_call_cleanup/3` to collect the pending promise before server teardown,
checks the original `nb_getval/2` sandbox rejection, and asserts that no
node-scoped promise remains. The original fixture failed the new resource
assertion; the repaired test passed 300 consecutive repetitions and three complete
T4 native runs. The test remains enabled without automatic retries. Both
dependency pins advance to consume this test-only fix while keeping browser
schema provenance aligned. The initial failure and diagnostic sample are retained
with the verification logs.
