# Default local pinned SWI startup — 24 October 2026

## Outcome

Normal local startup now selects native `swi-prolog-node` commit
`f316e65503bff863dfbd2e182f7487988c91480c`, with an explicit
`WP_NATIVE_MODE=legacy` alternative. All 18 automated groups passed, including
12 new startup regressions, native T4's 983 cases, colocated T4's 1004 cases,
interoperability, integration, legacy-layout and full WASM checks. Each mode also
passed 13 public API smoke checks and 18 URL/payload checks.

No native implementation files or existing test assertions/timeouts changed.
Installed engines, active runtime aliases, durable n3 launchers and existing
n3/n5 processes are unchanged. The local setup was prepared, but no live node
was reloaded or restarted. Temporary servers and agent-created UI tabs were
closed after verification.

## Startup selection

- `tools/setup_swi.py --native-root /path/to/swi-prolog-node` validates the existing
  checkout using the shared pin validator. It assembles browser sources into a
  content-addressed directory under ignored `.trinity/`, verifies existing
  generated payloads rather than overwriting drift, and atomically writes
  `.trinity/native-swi.json`.
- `demonstrator_startup.pl` centralises selection for `load.pl`, `run.pl` and
  `Deployment/start_node.pl`. The named deployment scripts that include
  `load.pl` also inherit that selection on their next startup.
- Pinned mode validates setup before node binding, loads the external native
  implementation through the origin-checking bootstrap, and sets the
  demonstrator asset and assembled browser-source paths from the checked state.
- Missing setup, a wrong/dirty pin, browser drift, unknown modes and mixed
  already-loaded native modules fail rather than silently using a local copy or
  installed pack. The validation subprocess supplies the setup recovery command.
- `WP_NATIVE_MODE=legacy` explicitly uses the retained native tree, with its
  previous asset-location overrides and no Python/setup/private-checkout
  requirement. `WP_NATIVE_STATE` can explicitly select another generated setup
  JSON file. Normal pinned startup requires Python 3 and Git.

No fetching, installation, repository visibility or credential change occurs.
Generated state contains machine-local paths and is excluded from Git and Docker
build contexts. `setup-paths.json` records the selected inputs as verification
provenance; it is not the operational configuration file.

`tools/pinned_swi.py` remains available as the earlier explicit wrapper, sharing
its pin/payload validation with setup. The native repository itself retains its
standalone `load.pl`; it does not acquire this demonstrator setup dependency.

## Compatibility boundary

The GitHub CI job and both Dockerfiles now explicitly set legacy mode, preserving
their existing colocated native selection while their dependency assembly is
still deferred. The minimal node Dockerfile also copies the central startup
module. A regression exercises that minimal file layout without `tools/`, a
private checkout or Python on PATH. No image was built/deployed and no GitHub CI
run is claimed here; image engine versions and remote CI provisioning were not
changed by this batch.

The extraction/split-layout tools now use a dedicated standalone native loader
from `tools/swi_repository_templates/load.pl`, rather than copying the newly
consumer-specific default loader. The extraction tool applies it in its existing
packaging stage, preserving the original source and extraction-history audit.
The standalone-loader regression proves that the generated native loader works
from a foreign CWD without the demonstrator setup or Python. The full historical
repository extraction was not repeated or republished.

The retained native source tree, shared schema, DTD, examples and shared language
manual remain in place. Native byte preservation is checked in `after.json`.
Runtime APIs, node options and source-loading semantics are unchanged. In pinned
mode the checked setup selects this demonstrator's assets/payloads; arbitrary
asset overrides retain their prior behaviour in explicit legacy mode.

The running n3 still has its previously loaded implementation. Its durable
launcher file was not changed; because it includes the repository loader, a
future deliberate restart would use the new default unless legacy mode is
explicitly selected. This batch performs no such cutover.

## Verification

`run.py` uses a disposable copy of the already verified complete SWI candidate
under `~/.local/share/trinity-runtime-tests/swi-default-startup-2026-10-24/runtime`.
It includes core `09b6299` and the local HTTP shutdown repair. Installed runtime
files were not used as writable test output or rebuilt. Existing Node was added
only to the subprocess PATH for browser checks.

| Check | Result |
| --- | --- |
| New default-startup regressions | 12/12 pass |
| Existing pin/dependency regressions | 6/6 pass |
| Existing extraction/packaging regressions | 3/3 pass |
| Native LINT, T0, T1_NATIVE, T2, T3_NATIVE | pass |
| Pinned native T4_NATIVE | all 983 cases pass |
| Native T5 historical-peer interoperability | pass |
| External-asset T1/T3/T4 integration selections | pass |
| Colocated T4_LEGACY_LAYOUT | pass |
| Complete original colocated T4 in explicit legacy mode | all 1004 cases pass |
| Full WASM tier, including Prolog and JS contracts | pass |
| Cross-repository statechart/schema equivalence | pass |
| Default loader origin audit from foreign CWD, with local library path present | 68 native modules from the pin; no retained native source loaded |
| Public HTTP/WebSocket smoke checks | 13/13 per mode |
| Existing routes and payload checks | 18/18 per mode |
| Native and SWI-WASM Worker real UI checks through default startup | pass |

The new regressions cover foreign-CWD default loading, explicit legacy without
setup, missing setup through `load.pl` and `run.pl`, failure before binding in the
environment-driven entry point, both modes' `WP_CHECK` success, dirty runtime and
browser rejection, invalid modes, preloaded local-module rejection, preservation
of corrupted existing generated files, the minimal legacy container layout,
and independent standalone native loader generation.

`run.pl` retains its existing fixed port 3060. Its missing-setup failure path was
tested without binding; its successful port-3060 bind was not attempted because
that would conflict with the existing n5 frontend. Successful actual server
startup used the ordinary `load.pl` path and public node API on isolated loopback
ports instead. Environment-driven startup's successful configuration-only
`WP_CHECK` path was exercised in both modes; its public configuration resolution
and bind code were not changed.

The temporary pinned server on 51856 and legacy server on 51857 used the same
existing shared database fixtures and browser assets. Smoke checks exercised
runtime properties, Unicode, private-source isolation, worker cleanup,
synchronous paging, supervisors, text/URI statecharts and monitor delivery,
promise timeout/retry, and sandbox rejection. Their origin records prove the
expected external versus colocated selection.

The 36 URL checks retain the existing route paths and verify byte identity for
six browser Prolog payloads, the DTD, example XML/alias, worker JavaScript and
bundle. Rendered HTML routes receive HTTP 200 and were exercised in the actual
UI; no claim of byte identity across differently configured port URLs is made.
The native UI returned `[a]` then `[b]` through synchronous wrappers. The Worker
UI loaded the same example URI, halted it and received its termination monitor.

Commands, exit statuses, durations and original external watchdogs are recorded
in `results.json`. No existing assertion or timeout was weakened. No unexplained
failed runtime trial was rerun and counted as a pass. The existing occasional
`current_output closed; set to user_output` notices remain in test logs and did
not fail assertions. The startup regression set grew from 11 to 12 cases when
the standalone extraction-loader compatibility check was added; all final cases
passed.

## Preservation and documentation

`before.json`, `after.json` and `summary.json` confirm unchanged n3/n5 process IDs,
start times/commands, active SWI installation hashes, Trealla binary/library
hashes, native repository revision/status, every retained local native file,
n3 durable launcher/rollback files and the active SWI alias. The macOS runtime
hashes also match the preceding controlled-update record.

The local `.trinity/` setup remains available for normal startup; it is ignored
and does not change any durable live launcher. README startup instructions,
`load.pl`/`run.pl` comments and the extraction map document setup, legacy mode,
asset selection and deferred CI/Docker/deployment cutover. Duplicate removal,
private-repository visibility, authenticated CI checkout and any live-node source
switch remain separate work.
