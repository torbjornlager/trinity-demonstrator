# Native SWI repository-extraction rehearsal — 23 October 2026

The local repository is `/Users/torbjorn.lager/Documents/GitHub/swi-prolog-node`.
This is a rehearsal, with no GitHub repository/remote created and no deployment
cutover. The original demonstrator remains complete. Installed engines, n3/n5,
tutorial URLs, examples and the shared language manual are unchanged.

## Source, history and file preservation

Source HEAD: `a75782d8d8e29ab8ad8330634f597e4b7f852980` in
`trinity-demonstrator`, plus the explicitly recorded example-helper preparation.
The destination is a full independent clone, with no object hard links and no
publishing remote. All 288 commits reachable through the source refs remain
reachable, including the remote-tracking `semantic-contracts` research branch
archived under `refs/archive/trinity-demonstrator/`. The original annotated
`demonstrator-peer` tag object is retained; its peer commit is pinned as
`2b5eae7ad4118e88f4aec77c513b6204dbf3b69e`.

`inventory.json` accounts for all 711 originally tracked files: 506 retained
in the native working tree; 205 excluded there but preserved in both original
checkout and original Git history. No original tracked file has been deleted.
The historical frontend files intentionally remain recoverable in native Git
history; this is not a history-size reduction or a filtered-history export.

The local rehearsal commits keep concerns separate:

- `2fea9be`: external example-helper seam and its two regression tests.
- `563c34b`: narrow the cloned working tree; no retained content edited.
- `cb72b5f`: native README/instructions and standalone default test selection.
- `33ce33b`: document preparation and preservation boundaries.

The original demonstrator retains its original default test driver. Native
runtime/test bytes match the prepared demonstrator source; package metadata
and loader are byte-identical. Assertions and timeouts were not weakened.
`preservation.json` and `history-preservation.json` record the audits.

A verified full source bundle is also retained outside both checkouts:
`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swi-repository-extraction-2026-10-23/source-a75782d.bundle`.
Its digest is in `history-preservation.json`.

## Small preparation changes

`statechart_actor:interpret_example/1` now reads a nonempty `WP_ASSET_ROOT`
without importing the node layer. An explicit root is authoritative; unset or
empty configuration preserves the original module-relative example path.
Ordinary source loading, sandboxing and URI semantics are unchanged. Two tests
check the external missing-source path and the original unset-path behavior.

`tools/package_wasm_prolog.py` assembles six browser Prolog payloads into a
fresh output directory, taking the shared schema from the selected native
checkout and the other five modules from the unchanged browser source. A hash
manifest identifies each input. Existing output directories are rejected.
No source payload is overwritten or deleted. The schema is packaged from the
native revision rather than maintained as an independent generated fork.

The existing equivalence tool keeps its original default paths, accepts
`--native-root` and `--wasm-dir`, and additionally rejects schema drift. Its
existing algorithm/helper comparisons are unchanged. Negative regressions
verify both schema drift and changed algorithm detection.

The reproducible extraction tool refuses existing destinations, preserves
source refs and files, separates preparation from working-tree extraction,
and generates native packaging instructions from checked-in templates. It
was also run successfully into a second disposable checkout; its native
runtime and default test driver match the named rehearsal repository.

## Verification

Engine: the existing separate PCRE-enabled build, not an installed runtime:
`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl`.
This is the previously verified build including Jan's `09b6299` fix. Node.js
for browser contracts is the existing bundled executable under
`~/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin`.

Results are machine-readable in `results.json`, `control-results.json` and
`followup-results.json`, with commands, working directories, durations and
separate complete logs. `run_checks.py`, `run_controls.py` and
`run_followups.py` preserve the exact verification harnesses.

| Check | Result |
| --- | --- |
| LINT | PASS (0.127 s) |
| T0 | PASS (7.244 s) |
| T1_NATIVE | PASS (0.565 s) |
| T2 | PASS (6.693 s) |
| T3_NATIVE | PASS (36.628 s) |
| T4-native-fresh-control | PASS (49.864 s) |
| T5 | PASS (1.275 s) |
| T1_INTEGRATION | PASS (0.133 s) |
| T3_INTEGRATION | PASS (4.197 s) |
| T4_INTEGRATION | PASS (1.546 s) |
| T4_LEGACY_LAYOUT | PASS (0.402 s) |
| WASM-with-node | PASS (162.538 s) |
| cross-repository-equivalence | PASS (0.04 s) |
| pack-attachment-corrected | PASS (0.239 s) |
| headless-api | PASS (0.239 s) |
| Packaging/extraction negative regressions | PASS (3 tests) |
| Independent export, history and file-preservation audits | PASS |

The initial native T4 run stalled at
`node:isobase_yield_timeout_callback_is_sandboxed` and reached the external
300-second watchdog. A fresh unchanged full native run passed all 983 tests
in 49.864 seconds. The isolated same test also stalled in the original
checkout at its external 30-second watchdog, while a fresh isolated native
control passed. The previous split-layout batch recorded this same diagnostic.
This remains an intermittent callback diagnostic, not a claimed root-cause
finding or a runtime repair in this batch. Its logs and nonzero results remain.

Two initial harness mistakes are retained in the first result set: Node was
not on PATH, so the browser's 64 Prolog tests and equivalence checks passed but
its JavaScript commands could not start; and the pack-version probe incorrectly
expected an atom rather than the existing string result. Follow-ups use the
bundled Node path and the correct string assertion. No product behavior was
changed to satisfy either probe.

## Reproduction and remaining boundary

See `docs/SWI_NODE_EXTRACTION_MAP.md` and the new repository README for commands.
`extraction.json` identifies the actual clone/commit sequence;
`reproduction/` records the second automated export. `native-packaging.patch`
also records the initial README/test-driver preparation for inspection.
`browser-package.json` records the assembled browser payload hashes.

Publishing `swi-prolog-node`, switching the demonstrator to a pinned native
dependency, adapting CI/Docker and removing duplicated native working files
are later work. Package name `web_prolog`, version, `library(web_prolog)` and
selective imports are preserved. Published package URLs are left untouched
until a public repository exists. Historical documentation is retained rather
than pruned during extraction.

The suggested names `trealla-prolog-node` and `gnu-prolog-node` are recorded
for a separate migration; neither directory nor remote repository was renamed.
Engine updates, live startup migration and the callback diagnostic are separate.
