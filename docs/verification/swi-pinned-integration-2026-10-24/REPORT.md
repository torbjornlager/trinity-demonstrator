# Pinned native SWI dependency integration — 24 October 2026

## Outcome and boundary

The demonstrator now has an explicit opt-in integration path using native
`swi-prolog-node` commit `f316e65503bff863dfbd2e182f7487988c91480c`. All 16 automated
check groups pass, as do 13 public HTTP/WebSocket smoke checks, 18 URL checks,
and temporary-node UI checks in native, SWI-WASM Worker and main-thread modes.

The existing native copies, default `load.pl`, test assertions/timeouts,
examples, language manual, Docker and CI selection remain unchanged. This is
an independently checked integration mode, not a live source or deployment
cutover. Installed runtimes, runtime aliases, n3 and n5 were not changed.
The extracted repository is private and was not modified.

## Pin and loading

`dependencies/swi-prolog-node.json` records the repository, exact revision and
unchanged pack name `web_prolog`.

`tools/pinned_swi.py` checks the selected checkout's HEAD and runtime/package
working-tree state before starting SWI. It rejects missing checkouts, a different
revision, modified schema/runtime files and untracked runtime modules rather
than silently falling back to local copies. It verifies all six assembled browser
payloads against the selected inputs and does not fetch or install dependencies.

`tools/pinned_swi_bootstrap.pl` selects the external Prolog library, imports its
ordinary API into the trusted startup context, and verifies loaded native module
origins. Mandatory roots include the umbrella library, node, actors, isolation
and shared SXML schema. Other loaded native modules are checked using their
module declarations, avoiding basename collisions with standard SWI modules.
An origin failure exits the process unsuccessfully.

The positive origin check ran from a foreign working directory with the
retained local Prolog directory explicitly present on the library path. All
**68 native modules** came from the pinned external checkout; no source under
the demonstrator's retained native Prolog directory was loaded. The temporary
UI node independently recorded the same boundary in `ui-origins.json`.

## Source and browser alignment

`source-alignment.json` compares each retained native Prolog-tree file. All
runtime, schema and DTD bytes match the demonstrator's copies. The only difference
is the demonstrator runtime README's later local n3 update notes. It is recorded
as a documentation difference; neither repository's runtime was edited to hide it.

`package_wasm_prolog.py` assembled the five unchanged browser modules from the
demonstrator and the authoritative `sxml_schema.pl` from the pinned native
checkout. `browser-package.json` records paths and hashes. The output is a fresh
private working directory, not a replacement for any live payload.

The wrapper sets `WP_ASSET_ROOT` to the demonstrator and `WP_WASM_SOURCE_DIR` to
the checked assembled payloads. Existing paths such as `/portal`, `/manual`,
`/admin`, `/editor_frame`, `/examples_index`, `/examples/...`, `/statecharts/...`,
`/wasm/...`, `/sxml-0.2.dtd`, and browser JavaScript URLs remain available.
`url-checks.json` records 18 successful routes; byte comparisons cover all six
assembled Prolog files, the native DTD, the example XML and its alias, and the
browser worker/bundle assets. Rendered HTML routes are checked for HTTP 200 and
exercised in the real UI rather than claimed byte-identical across different ports.

## Verification

`results.json` records exact commands, working directories, durations and outer
watchdogs. No failed runtime trial was retried to count as a pass. Existing test
bodies, assertions and timeouts were not changed.

| Check | Result |
| --- | --- |
| New pin/dependency negative regressions | 6/6 pass |
| Existing extraction/packaging negative regressions | pass |
| Native LINT, T0, T1_NATIVE, T2, T3_NATIVE | pass |
| Native T4_NATIVE | all 983 scheduled cases pass |
| Native T5 historical-peer interoperability | pass |
| T1_INTEGRATION, T3_INTEGRATION, T4_INTEGRATION with external assets/payloads | pass |
| Original demonstrator T4_LEGACY_LAYOUT | pass |
| Full demonstrator WASM tier | pass, including 64 Prolog cases and JS checks |
| Cross-repository statechart/schema equivalence | pass |
| Pinned loader origin check from foreign CWD, with local library path present | pass |
| Temporary pinned-node HTTP/WebSocket smoke | 13/13 pass |
| Existing URL and payload checks | 18/18 pass |
| Real UI: native, Worker, main-thread | pass |

Native tests execute from the external checkout's own driver. The full-node
consumer bootstrap is deliberately not injected into lower-tier tests, preserving
their existing no-higher-layer-loaded assertions. T5 uses the checksummed fixture
in the clean native snapshot, without depending on the removed Git history.

The separate test engine is a disposable copy of the verified complete SWI
prefix, including core `09b6299` and the local HTTP shutdown repair. Its location
is `~/.local/share/trinity-runtime-tests/swi-pinned-integration-2026-10-24/runtime`.
The test run did not use or rebuild installed runtimes. Browser JS checks used
the existing bundled Node executable, added only to subprocess PATH.

The temporary node bound loopback port 51855, served demonstrator assets and
shared database fixtures, and loaded its native implementation through the pin
wrapper. The public API smoke cases cover private-source isolation, Unicode,
worker cleanup, synchronous paging, supervisors, statecharts from text/URI,
monitor delivery, promise timeout/retry and sandbox rejection. In the native UI,
synchronous pages returned `[socrates]` then `[plato]`. Worker and main-thread
browser UIs both loaded the example statechart via its unchanged URI path and
received halt/monitor results; the Worker UI also ran `parallel/1`.

The temporary node and both agent-created browser tabs were closed after saving
screenshots/transcripts. The main-thread mode preference was changed only on the
temporary port's browser origin, not the user's live n3 origin.

## Draft diagnostics and remaining qualifications

Two draft checks were corrected before the recorded acceptance batches:

- The first alignment assertion treated the known README update as runtime drift.
  File roles now record that documentary difference while retaining exact runtime
  byte equality.
- A draft origin checker matched native files by basename and incorrectly confused
  SWI's standard `debug.pl` with Web Prolog's distinct module. The final checker
  uses native module declarations and mandatory module/file pairs. The accepted
  origin record includes both the standard library and correct native modules.

No runtime change was needed. The occasional `current_output closed; set to
user_output` notice in native test output is retained; it did not fail assertions.
The callback stall that affected earlier extraction rehearsals was already
resolved in the separate test engine's HTTP-library patch. This batch does not
claim that patch has been merged upstream.

The repository remains private. Cross-repository CI credentials/permissions,
visibility changes, default dependency selection, Docker/deployment migration,
duplicate removal and package distribution remain separate work. No network
checkout or permission change was needed for this local integration.

## Preservation and reproducibility

`before.json` and `after.json` confirm unchanged:

- n3/n5 and auxiliary/frontend process IDs, start times and commands;
- every file hash in the active SWI installation;
- Trealla executable and library hashes;
- extracted native repository revision and clean working status;
- every retained local native file hash, including the README.

`summary.json` consolidates these checks. `run.py`, `start-ui.py`, `smoke.py` and
`ws-smoke.pl` record the automated and temporary-node harnesses. Follow
`docs/SWI_NODE_EXTRACTION_MAP.md` for the reusable pin/package/load commands.
`run.py` expects the recorded disposable runtime and assembled payload directory;
it does not install them or alter an existing destination.

This establishes the pinned integration boundary while preserving the complete
colocated demonstrator. A later batch can choose how to make this dependency the
default and prepare CI/Docker assembly before removing duplicate native files.
