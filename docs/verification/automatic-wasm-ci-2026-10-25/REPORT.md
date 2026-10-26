# Automatic SWI-WASM CI — 25 October 2026

## Change

`.github/workflows/ci.yml` adds an independent `wasm` job to the existing
push/pull-request/manual workflow. It has no `needs` dependency or manual-only
condition. The existing native `test` and optional `pinned-native` jobs, workflow
triggers and concurrency policy are unchanged.

The job uses the existing checksum-pinned SWI 10.1.19 composite setup and
`actions/setup-node@v6` with Node.js 22. It runs exactly the existing
`bash tools/test.sh WASM` tier under `tools/ci_timeout.py` with the established
360-second deadline. No test, assertion, sleep, source or runtime behavior was
changed. `WP_NATIVE_MODE=legacy` selects retained local schema inputs, avoiding
private dependency access. The separate pinned-native integration gate remains
manual and unchanged.

The tier includes native shared-statechart checks, the Worker and coordinator
smoke checks, and real WASM-engine semantic contracts for Worker and main-thread
compatibility mode. That includes character-list reading and output ordering.
Node-hosted contracts do not replace actual browser UI testing.

The shell step uses `set -euo pipefail`: logging with `tee` cannot turn a failed
WASM run into success. An `always()` upload step retains `WASM.log` and
`versions.log` as the `wasm-results` artifact. Its 20-minute job bound includes
source-build setup, with no change to existing per-test timeouts or the native
jobs' deadlines. No repository credential, native dependency pin or runtime
selection was changed.

## Verification

Base commit: `290bc0312f01163f361ac1290dbd58ee7f643080` plus this CI-only batch.

[The exact new shell step](workflow-step.sh) was extracted from the workflow
YAML and run unchanged against the existing test suite. The local run used
separately extracted official Node 22.23.4 and official SWI-Prolog 10.1.19 on
macOS arm64. Neither replaced an installed executable or a live node runtime.
Node's archive was checked against its official checksum listing; see
[download provenance](node.json). SWI extraction/provenance is recorded in
[the earlier CI prerequisite checkpoint](../swi-ci-10.1.19-2026-10-25/REPORT.md).
`run.py` records the scoped executable paths and reruns the shell step.

The full unchanged tier passed (exit 0) in 170.759 seconds, with 2,751 `ok`
assertion lines and the final `all scenarios passed` marker.

[Run result](run-results.json), [full WASM log](wasm-ci-results/WASM.log),
[commit/engine versions](wasm-ci-results/versions.log).

Workflow validation parsed the YAML and checked shell syntax, identical native
job definitions and triggers, independent WASM scheduling and unconditional
artifact retention. Controlled pipeline fixtures ran the exact shell step with
an isolated stub tier returning 0 and 7. The step returned the same status in
each case and retained its log and version metadata. No repository test was
stubbed or modified during the full WASM run. See
[checks](workflow-checks.json) and the rerunnable `check_workflow.py`.

Hosted Ubuntu execution of this new job remains pending a commit and push. The
local macOS run does not claim a completed hosted CI result. The Linux source
setup itself is unchanged from the previously successful SWI 10.1.19 native CI
run; no new browser UI session was needed for this workflow-only change.

## Preservation

[Before hashes](before.json) and [preservation checks](preservation.json) cover
all running node identities, selected native engine/launcher hashes, current
live asset selection, native dependency pin and unchanged test/runner files.
The live browser assets remain at the already selected repaired commit; this
batch did not change them. No runtime code, installed engine, running node,
assertion, book example, native repository or private-repository access changed.

## Additional verification requested afterward

A clean-export full-tier run, 30 focused scenario repetitions and controlled
timeout/log-writer/missing-engine checks also passed. See the
[extended verification report](extended/REPORT.md), including the corrected
temporary fixture exit-status assumption. No runtime or language-test changes
were required.
