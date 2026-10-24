# Pinned native SWI CI integration — 24 October 2026

## Scope

Prepare an explicit pinned-dependency CI path while retaining the automatic
legacy comparison. No repository access, credentials, runtime source, installed
engine, live-node launcher or running n3/n5 process is changed. No GitHub Actions
run was dispatched. The native repository remains private; successful remote
checkout still needs an authorized dependency-read credential.

## Changes

The existing `CI / test` push/pull-request job and its tier command are retained.
A manual `workflow_dispatch` boolean, `pinned_native` (default false), selects a
separate read-only-permissions job. It obtains the repository and full SHA from
the existing manifest, checks out exactly that commit with credentials not
persisted, and invokes `tools/ci_pinned_swi.py`. It uses an owner-supplied
`SWI_NODE_READ_TOKEN` secret if one exists, otherwise the ordinary workflow token.
No secret is created or access granted by this batch. Missing private-repository
access fails checkout rather than skipping tests or falling back to local copies.
The job retains the existing SWI PPA installation recipe and installs Node 22 for
browser checks; no new engine build or deployment policy is introduced.

The runner never fetches or installs. It validates the pin before tests, creates
new isolated setup/browser outputs and audits loaded native module origins with
the retained local library path explicitly present. Native layer tests execute
from the dependency checkout without a full-node preload. Integration selections
use the demonstrator's assets and assembled payloads. Each group has the existing
CI's 360-second outer watchdog; test failures/timeouts are retained and subsequent
groups still execute. Logs, provenance and results are uploaded on Actions even
when a check fails. Its 40-minute job bound allows the larger selection; no
predicate timeout or existing assertion is changed.

The startup regression fixture now accepts `PINNED_SWI_TEST_ROOT`; its sibling
checkout default and assertions are preserved. Six runner regressions cover
manifest selection/rejection, external test routing, origin-audit inclusion,
failure aggregation, timeout reporting and rejection before test setup.
README and extraction map distinguish this prepared opt-in path from an active
automatic cross-repository gate. Docker assembly and native-copy removal remain
separate work.

## Local verification

The same CI runner is exercised against exact native revision
`f316e65503bff863dfbd2e182f7487988c91480c` using the preserved separate candidate at
`~/.local/share/trinity-runtime-tests/swi-default-startup-2026-10-24/runtime`.
This has the protected-wait and HTTP-shutdown fixes already verified in preceding
batches; it is not an installed runtime modified for these checks. Matching Node
was placed on subprocess PATH. `checks/provenance.json` records engine/version,
native pin and demonstrator base commit. Changes in this batch are uncommitted
at verification time and are identified by the eventual commit containing this
report.

- `checks/results.json`, `runner.log`: pinned native/integration/browser run.
- `legacy/results.json`, `legacy-runner.log`: unchanged legacy LINT/T0–T5 run.
- `runner-regressions-final.log`: six orchestration regressions, all pass.
- `checkout-outputs.txt`: manifest-derived Actions checkout coordinates.
- `checks/origin-audit.log`: actual module/file origins.
- `before.json`, `after.json`, `preservation.json`: retained source bytes,
  installed executable hashes/targets, native checkout status and live processes.

Workflow YAML parses using Ruby's YAML parser. The legacy tier shell block is
byte-identical to the pre-batch version. This is syntax/local execution
verification, not a claim of GitHub-hosted authentication, Actions execution,
Linux equivalence, new browser UI interaction or Docker image testing. Engine
prerequisites remain explicit in the README.

## Final results

All **16/16 pinned check groups** and **7/7 legacy tiers** passed, with no
watchdog timeouts. Native T4 completed 983 cases; legacy T4 completed 1,004.
The full WASM tier, including its JavaScript contracts, passed. Startup
regressions passed 12/12, existing pin regressions 6/6 and new runner regressions
6/6. No failed runtime trial was retried or relabelled. The final lightweight
runner regression rerun also passed after closing the setup log explicitly;
test commands and assertions did not change.

All preservation comparisons pass: every retained Prolog source byte, native
repository revision/status, installed executable target/hash, and n3/n5 process
identity/start time/command is unchanged. Generated browser payload copies were
removed after verification; their hashes remain in payload-hashes.json. The
historical setup state records their run-time paths and is not operational
configuration to reuse. No ordinary local setup was overwritten.
