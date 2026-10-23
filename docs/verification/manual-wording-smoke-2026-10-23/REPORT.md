# Manual-wording smoke repair — 23 October 2026

Both requested checks pass: the standalone RPC bridge smoke test and the full
WASM tier exit 0. The manual, runtime sources and installed engines are unchanged.

The test previously required the obsolete sentence “All conforming native and
browser runtimes accept:”. The current manual lists API options once and then
documents implementation differences explicitly. That single wording requirement
was removed; the manual was not rewritten to satisfy it.

The other eight conditions remain unchanged and now run as independently labelled
assertions: runtime_property/1, main@localhost, http_timeout/1, absence of offset
from RPC options, presence of offset in promise options, the default promise
timeout answer, and absence of the two obsolete runtime-specific option-list
introductions. A failure now identifies its condition instead of only reporting
a broad common-contract mismatch.

## Verification

| Invocation | Result | Evidence |
|---|---|---|
| `node tests/wasm/swi_wasm_rpc_bridge_smoke.js` | pass, exit 0; all eight manual assertions pass | rpc-bridge-smoke.log |
| `bash tools/test.sh WASM` | pass, exit 0 | wasm-tier.log |

The full tier includes the statechart equivalence guard, SWI statechart tests,
Worker smoke, RPC bridge smoke and all WASM semantic contract scenarios. These
are the repository's Node-hosted WASM fixtures; this batch did not repeat browser
UI testing or the native interoperability matrix.

The launcher explicitly selects bundled Node.js and the separate PCRE-enabled
Jan-fix SWI build, avoiding the earlier PATH issue. Neither executable was
installed or rebuilt. External process-group watchdogs bound both invocations.
Exact paths, commands, exit codes and durations are in [results.json](results.json).

[before.json](before.json) and [provenance.json](provenance.json) record preserved
manual/runtime/installed executable hashes, selected executable hashes and the
test source hash. The only modified tracked file is the smoke test. The new
verification directory contains the runner and evidence; no shared manual,
runtime implementation, book example or installed runtime changed.

From the demonstrator repository:

```sh
python3 docs/verification/manual-wording-smoke-2026-10-23/run.py
```

This resolves the stale wording failure recorded in the preceding acceptance
checkpoint. Separate native-engine diagnostics remain separate; this result is
not an installed-runtime upgrade.
