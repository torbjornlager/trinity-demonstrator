# Native SWI node extraction: files, dependencies and first seam

Status: default local pinned startup, opt-in pinned CI and maintenance ownership
clarified, 24 October 2026. The separate
`swi-prolog-node` repository now exists privately on GitHub with a clean initial
snapshot (`f316e65503bff863dfbd2e182f7487988c91480c`). Its earlier extracted
history was replaced at the owner's request; the original demonstrator and
private preservation backup retain that history. Historical rehearsal details
below describe the earlier stage and do not describe the new repository's
current ancestry.

No native copies have been removed from the demonstrator. Default local `load.pl`,
`run.pl` and environment-driven startup select the validated native dependency.
Automatic CI and Docker retain legacy selection; a manual pinned CI job is now
prepared without provisioning private-repository access. Live n3/n5 selection and
installed runtimes remain unchanged. Setup does not fetch, install, publish or
switch live nodes.
See the current integration sections and the
[maintenance guide](SWI_NODE_MAINTENANCE.md). Historical stage descriptions below
are retained; they are not the current maintenance procedure.

## Ownership map

| Current paths | Responsibility | Intended home |
| --- | --- | --- |
| `prolog/web_prolog.pl`, native `prolog/web_prolog/*.pl` | Native SWI library: actors, isolation, behaviours, distribution, HTTP/WebSocket server, policy and administration backend | SWI implementation repository |
| `prolog/web_prolog/sxml-0.2.dtd` | Grammar served at `/sxml-0.2.dtd`; shipped beside the node implementation | Retain with the runtime for the first extraction; preserve one authoritative schema source |
| `prolog/web_prolog/shared_db.pl` | Default node shared database, loaded by `node_startup_options.pl` | Retain as a runtime-shipped default initially; distinguish its example content from the shared-db mechanism |
| `web/*.html`, `web/vendor/`, `web/tabler.min.css`, `img/` | Portal, tutorials, shared language manual, browser editor, discovery/admin presentation, vendored browser dependencies | Demonstrator repository; native administration backend remains in the runtime |
| `web/swi_wasm_actor_worker.js`, `web/swipl-bundle.js`, browser code embedded in `web/demonstrator.html` | Worker and main-thread browser runtimes and their host integration | Demonstrator repository initially |
| `prolog/web_prolog/wasm/{shared_db,statechart_wasm*}.pl` | Five browser-only Prolog sources fetched through `/wasm/` | Demonstrator/browser ownership; physical move deferred |
| `prolog/web_prolog/wasm/sxml_schema.pl` | Shared SXML validator: imported directly by native `statechart_model.pl` and served to browsers | Must remain available in the native package at its current path for now; one authoritative source, with pinned browser packaging resolved before extraction |
| `examples/actors/`, `examples/statecharts/` | Tutorial/example sources, served with original relative URLs | Demonstrator repository; language examples remain unchanged |
| `pack.pl`, `load.pl`, native runtime README | Library packaging, operator entry point and implementation documentation | SWI implementation repository |
| `tests/tiers/t0_actors.pl`–`t5_interop.pl`, tier support modules | Native library/server regression tests, with some frontend/content checks mixed into T4 and historical peer extraction in T5 | Native tests follow the implementation; separate frontend checks explicitly before extraction |
| `tests/wasm/`, `tests/test_statechart_wasm.pl`, statechart equivalence check | Browser-runtime contracts and shared native/browser statechart checks | Demonstrator/integration CI, with an explicit pinned native dependency |
| `tools/test.sh`, `tools/generate_dependency_graph.py`, `.github/workflows/` | Present single-checkout test and build orchestration | Divide native CI from demonstrator integration CI; preserve every existing assertion |
| `Deployment/` | Current SWI image, node startup, Caddy and multi-node deployment; optional other-runtime overrides | Separate native node image/startup from demonstrator assembly; keep deployment configuration compatible |
| `docs/verification/`, existing migration/design documents | Provenance and investigation history | Preserve useful history and links; distinguish historical records from current setup instructions |
| Sibling `trinity-conformance/` repository | Common interoperability baseline, public-interface cases and coverage | Remains shared and independent |

## Runtime dependencies already separated by layering

- Layer 0: `actors.pl`, `wire_text.pl`.
- Layer 1: isolation, source utilities, actor I/O support and worker cleanup.
- Layer 2: toplevels, parallel/first-solution, server/supervisor/statechart behaviours.
- Layer 3: distribution, remote protocol, RPC and node controller.
- Layer 4: node server, policy, observability, administration and composition glue.
- Layer 5: `prolog/web_prolog.pl`, the umbrella library.

The source-of-truth layer assignment remains `tools/generate_dependency_graph.py`.
The new `node_assets.pl` is layer 4 under its existing `node*` classification.
Only `node.pl` and `node_admin.pl` import it; no lower layer gains an upward
import. Lower-layer loading remains independent of browser assets.

## Coupling addressed in this batch

Previously, 18 fixed page/directory resolvers in `node.pl` and two admin
lookups in `node_admin.pl` assumed `../../web`, `../../img` or `../../examples`
relative to their source files. The WASM source resolver assumed a sibling
`wasm/` directory, then tried the working-directory checkout.

Those node-layer lookups now delegate to `node_assets.pl`. This is a path
configuration seam: handlers, route registration, file content, MIME choices,
cache options, example filtering, request-path checks, logging and execution
policy remain where they were. Existing missing-file/failed-handler HTTP error
mapping is also unchanged. No API/source-loading protocol was added.

### Configuration

Use absolute paths for stable operation across working directories:

```sh
WP_ASSET_ROOT=/path/to/trinity-demonstrator \
WP_WASM_SOURCE_DIR=/path/to/browser-prolog-sources \
swipl load.pl
```

The same settings can be set by trusted operator startup code before serving:

```prolog
:- use_module(library(settings)).
:- use_module(library(web_prolog)).
:- set_setting(node_assets:root, '/path/to/trinity-demonstrator').
:- set_setting(node_assets:wasm_directory, '/path/to/browser-prolog-sources').
```

| Setting / environment default | Resolution |
| --- | --- |
| `node_assets:root` / `WP_ASSET_ROOT` | Root containing `web/`, `img/` and `examples/`. Empty preserves the runtime-relative checkout root. |
| `node_assets:wasm_directory` / `WP_WASM_SOURCE_DIR` | Explicit directory containing the six allowlisted browser `.pl` files. Takes precedence over the root. |
| Explicit root, empty WASM override | Browser sources at `Root/prolog/web_prolog/wasm/`, matching today's demonstrator tree. |
| Both empty | Original sibling `wasm/` lookup, followed by the original CWD fallback. |

Explicit locations are authoritative: missing files do not fall back to another
checkout. Settings are process-wide and shared by all HTTP listeners in that
SWI process; per-node asset-root options and live admin editing are outside this
batch. Environment values are settings defaults, not options in `node/2` or
public Web Prolog predicates. Configure them when starting a separate process;
existing n3/n5 processes are unchanged.

### URL contract

All current routes remain registered:

- `/portal`, `/demonstrator`, `/discovery-hub`, `/tutorial`, the profile/API
  tutorial URLs, `/jev-sxml-tutorial`, `/manual`, `/editor_frame`.
- `/admin` and `/admin/tabler.min.css`; admin API endpoints are unchanged.
- `/swi_wasm_actor_worker.js`, `/swipl-bundle.js`, `/vendor/...`, `/img/...`.
- `/examples/...`, `/statecharts/...`, `/examples_index`, `/wasm/...`.
- `/sxml-0.2.dtd` retains its runtime-shipped grammar.
- `/call`, ISOTOPE routes, `/ws`, health/configuration/observability routes and
  the root shared-database response retain their existing handlers.

A separate runtime can serve an external demonstrator tree on its existing
origin. Relative examples/source URIs, Worker URLs, WebSocket routing and
same-origin browser restrictions therefore need no change solely because of
repository extraction. Static-file roots do not change source-fetch allowlists,
sandbox checks or client-provided `src_uri/1` resolution.

## Dependency status through the extraction rehearsal

1. **Lower-layer example convenience helper — resolved for rehearsal.**
   `statechart_actor:interpret_example/1` still resolves
   `../../examples/statecharts` directly. It cannot import layer-4 node assets.
   The repository rehearsal now lets this helper use `WP_ASSET_ROOT` directly,
   without an upward import. An unset/empty root preserves the original path;
   an explicit root is authoritative. Ordinary statechart execution and URI
   fetching are unchanged.
2. **WASM ownership and equivalence checks.**
   Keep the two browser runtimes and six Prolog files together initially.
   `tools/check_statechart_wasm_equivalence.py` now accepts explicit native and
   browser paths and verifies shared-schema equality. CI must supply a pinned
   native checkout rather than silently follow its development branch.
3. **Historical peer and external launchers.**
   Native/integration test selections and test-only external asset resolution
   are now explicit (see the rehearsal below); assertions remain in their
   existing units. T5 still materializes `demonstrator-peer` using Git history;
   the repository rehearsal retains and verifies that tag/history and runs T5
   inside the new native checkout. Trealla interop and conformance launchers
   still refer to sibling native paths and need an explicit pinned native
   dependency before cutover.
4. **Packaging and entry points.**
   Preserve `library(web_prolog)` and selective layer loads. `debug.pl` expects
   `../../load.pl`; `node_version.pl` discovers `../../pack.pl` and `.git`.
   These are native package-layout assumptions rather than frontend assets,
   and the rehearsal checks package attachment and native source identity from
   a foreign working directory. Published source archives still need their
   release/build wiring.
5. **Deployment and integration.**
   The current Dockerfile copies the whole checkout to `/app`; startup scripts,
   examples, tests, browser UI and CI assume that arrangement. Later assembly
   should pin one native revision and mount/configure the demonstrator tree,
   with one authoritative native source copy. Do not change live startup paths
   while merely moving repositories.
6. **Documentation and shared definitions.**
   Preserve the single language manual and book links. Runtime implementation
   guides belong with each runtime. Review schema/shared-db packaging and stale
   repository URLs deliberately; they do not move automatically with native `.pl`
   files.

Verification for the original path-configuration seam is in
`docs/verification/configurable-assets-2026-10-23/`. The newer split-layout
results are described below.


## Split-layout rehearsal

`tools/check_swi_split_layout.py` creates a fresh disposable directory with:

- `native/`: `pack.pl`, `load.pl`, `LICENSE`, native READMEs, the native Prolog
  modules and DTD, tier tests/support, and native `tests/test_statecharts`
  fixtures. It contains no `web/`, `img/`, `examples/` or `.git`, and no symlinks.
  The sole file under its `wasm/` subdirectory is the required shared
  `sxml_schema.pl`; browser execution modules are absent.
- `demonstrator-assets/`: unmodified `web/`, `img/`, `examples/`, the six browser
  Prolog payload files, and the existing n3/n5 shared-db overlay files used as
  integration data. No deployment process is started or changed.
- `foreign-cwd/`: an empty working directory used to verify the standalone
  native package loader and HTTP API without a checkout-relative CWD.

The report's `manifest.json` records every copied file, its role and SHA-256.
Both schema copies are byte-identical exports of the current authoritative
source; this rehearsal does not create independently maintained schema forks.

Example (choose a fresh work directory on every invocation):

```sh
python3 tools/check_swi_split_layout.py \
  --swipl /path/to/separate/verified/swipl \
  --work-dir /tmp/swi-split-layout-rehearsal \
  --report-dir /tmp/swi-split-layout-results
```

The test-only `test_layout.pl` resolves demonstrator inputs using
`WP_ASSET_ROOT`, with the original checkout as the unset default. It imports
no node modules, so T1/T3 layer-honesty checks remain effective. Direct example
and HTML reads now use that helper. Relative-URI tests retain their original
URI strings and use the external example tree as their test working directory.
The two existing deployment overlays are read from that same external tree;
the native shipped shared database remains in the native package.

`test_partition.pl` explicitly classifies loaded declarations. No test is
conditionalized on asset availability, and nothing is skipped on a missing
file. Unknown units and stale named classifications fail. The audit compares
the exact multiset of loaded declaration IDs with the union of the selectors,
proving exhaustive and disjoint coverage.

| Tier | Native declarations | External integration declarations | Legacy-layout declarations |
| --- | ---: | ---: | ---: |
| T1 | 65 | 1 | 0 |
| T3 | 293 | 14 | 0 |
| T4 | 983 | 19 | 2 |

These are declaration counts; existing `forall` expansion and condition gates
are unchanged. For example, T3's existing distribution-dependent named-creation
condition remains inactive in its lower-layer native profile.

The original full tiers retain their original unit lists and order. Explicit
additional goals are available through the test driver:

```sh
./tools/test.sh T1_NATIVE T3_NATIVE T4_NATIVE
WP_ASSET_ROOT=/path/to/demonstrator \
WP_WASM_SOURCE_DIR=/path/to/demonstrator/prolog/web_prolog/wasm \
  ./tools/test.sh T1_INTEGRATION T3_INTEGRATION T4_INTEGRATION
./tools/test.sh T4_LEGACY_LAYOUT
```

The last gate deliberately runs in the original colocated checkout. Its two
existing assertions require actual files at the original default paths. It
preserves that compatibility contract separately from external integration.
Unqualified `./tools/test.sh` still runs the original full tiers once; it does
not additionally execute all the new selections.

The rehearsal also runs the original full T4 in the checkout. Its results,
including any intermittent diagnostics and bounded reruns, are retained in
`docs/verification/swi-split-layout-2026-10-23/REPORT.md`.

## What this establishes, and the next boundary

The native package can load and serve its API with no frontend tree present;
existing frontend URLs and example integrations work with a separately located
asset tree. Tests now express that boundary without moving or weakening their
assertions. No runtime source was changed in this batch.

After that split-layout batch, the next work was repository/history and dependency wiring:
choose the native repository and preserve useful history; retain a reproducible
T5 peer; make the demonstrator consume one pinned native revision; package the
shared schema for both consumers; and adjust deployment/build assembly. The
lower-layer `interpret_example/1` convenience helper and WASM equivalence tool
remain explicitly deferred. No live startup paths, engines, n3 or n5 were
changed by the rehearsal.


## Local repository-extraction rehearsal

The sibling `swi-prolog-node` directory is an independent Git clone, not a move
or a symlink. The source is `a75782d8d8e29ab8ad8330634f597e4b7f852980` plus the
explicit example-helper preparation. Original commit IDs, the annotated
`demonstrator-peer` tag and archived source refs (including the remote-tracking
`semantic-contracts` branch) remain reachable. There is no publishing remote.
A separately verified full source bundle is retained outside both checkouts.

The first new commit contains only the example-helper seam and regressions.
The next commit narrows the working tree without editing retained files. A
third commit documents the native checkout and makes its default test selection
native-only. `pack.pl`, `load.pl`, `library(web_prolog)`, the DTD, native source
paths and the historical peer contents remain compatible. The package is still
named `web_prolog`; the repository/directory name is `swi-prolog-node`.

The inventory accounts for all 711 originally tracked files: 506 retained in
the native working tree, 205 excluded there but preserved in the original
checkout and Git history. This includes useful investigation documentation;
its historical layout descriptions have not been rewritten wholesale.
The demonstrator remains complete and independently usable during rehearsal.

Reproduce into a fresh destination (never an existing directory):

```sh
python3 tools/rehearse_swi_repository_extraction.py \
  --destination /fresh/path/swi-prolog-node \
  --report-dir /fresh/path/extraction-results
```

The tool refuses existing destinations and verifies that original source bytes
remain unchanged. Its preparation commit copies the two explicitly named
helper/test files from the current checkout. The verification record includes
the separate native README/test-driver packaging patch.

Browser assembly now takes its shared schema from the selected native revision:

```sh
python3 tools/package_wasm_prolog.py \
  --native-root /path/to/swi-prolog-node \
  --browser-root /path/to/trinity-demonstrator \
  --output /fresh/path/browser-prolog
python3 tools/check_statechart_wasm_equivalence.py \
  --native-root /path/to/swi-prolog-node \
  --wasm-dir /fresh/path/browser-prolog
```

The fresh output contains the five unchanged browser modules, the native
schema and a hash manifest. Neither source tree is overwritten. The default
same-checkout equivalence command still works and now also rejects schema
mismatches. Do not maintain generated schema copies independently. Existing
browser URLs are preserved using `WP_WASM_SOURCE_DIR` for assembled payloads.

T5 continues to extract its original peer from the preserved tag, whose commit
is pinned in the extraction tool as
`2b5eae7ad4118e88f4aec77c513b6204dbf3b69e`. It launches temporary processes on
fresh ports; it does not connect to the existing n3/n5. Integration gates use
the original demonstrator as the configured external asset root. Browser tests
remain in the demonstrator. Legacy colocated-path assertions still run there.

Results, diagnostics, the original per-file inventory, packaging patch and
history/preservation checks are recorded in
`docs/verification/swi-repository-extraction-2026-10-23/`.

### Still deliberately deferred

- Making the privately published repository public, if desired. Local opt-in
  pinned integration and local default startup are now implemented; removing
  duplicate native working files remains a separate step.
- Cross-repository CI and Docker/deployment assembly; live startup migration.
- Publishing package/release distribution details. The native pack's home URL
  already points at `swi-prolog-node`; package name and version remain unchanged.
- Renaming Trealla/GNU directories or remote repositories. The proposed names
  `trealla-prolog-node` and `gnu-prolog-node` fit the same naming scheme, but
  their path consumers and GitHub redirects need their own bounded migration.
- Pruning or reorganizing historical documentation. Retention takes priority
  during this rehearsal.


## Current pinned-dependency integration — 24 October 2026

`dependencies/swi-prolog-node.json` pins the native repository and exact commit.
`tools/pinned_swi.py` validates that HEAD and rejects changed/untracked runtime
or package files before starting SWI. It checks all six assembled browser
payloads against their selected native/browser inputs. Missing or mismatched
inputs fail explicitly; the wrapper never fetches a repository or falls back to
the retained native copies. Documentation-only working changes do not change
runtime loading, but a different HEAD still requires an explicit pin update.

`tools/pinned_swi_bootstrap.pl` loads `library(web_prolog)` from the external
checkout, makes its public imports available for trusted startup goals, and
checks mandatory modules plus each loaded native module's declared module/file
pair. It also rejects loaded sources from the retained local native tree.
The check handles module names explicitly: standard SWI `debug.pl` and Web
Prolog's same-basename module are distinct modules. A foreign working directory
and an explicitly present local library search path are verification controls.

The runtime files in the two repositories are byte-identical at this checkpoint.
The demonstrator runtime README alone has additional local n3 update notes;
`source-alignment.json` accounts for this documentation difference without
changing either runtime copy.

From the demonstrator checkout, with a fresh output directory:

```sh
python3 tools/pinned_swi.py --native-root ../swi-prolog-node --check
python3 tools/package_wasm_prolog.py \
  --native-root ../swi-prolog-node --browser-root . \
  --output /fresh/path/browser-prolog
python3 tools/pinned_swi.py \
  --native-root ../swi-prolog-node \
  --swipl /path/to/verified/swipl \
  --wasm-dir /fresh/path/browser-prolog \
  -- -q -g 'pinned_swi_bootstrap:check_origins' -t halt
```

For a temporary server, append an ordinary trusted startup goal through `-g`.
The wrapper sets `WP_ASSET_ROOT` to this demonstrator checkout and
`WP_WASM_SOURCE_DIR` to the checked assembled payload directory. The verification
record includes a loopback-bound temporary-node launcher; it is not a live n3/n5
launcher. Package attachment and `library(web_prolog)` compatibility remain.

Native unit and integration tests run from the pinned checkout's own driver,
so lower-tier tests retain their existing no-higher-layer-loaded assertions.
The consumer bootstrap intentionally loads the full node and is not injected
into those independent layer tests. Browser and legacy-layout tests remain in
the demonstrator; cross-repository equivalence checks use the selected native
root and assembled schema explicitly.

Tests and evidence: [pinned integration record](verification/swi-pinned-integration-2026-10-24/REPORT.md).
Pin/source/payload rejection tests are in `tests/test_pinned_swi_dependency.py`.
The existing extraction and equivalence negative assertions remain intact.

The private repository is sufficient for this local mode. Authenticated
cross-repository CI checkout, native CI ownership,
Docker/deployment assembly, duplicate removal and repository visibility remain
separate work. No credential or permission change is part of this batch.


## Default local startup — 24 October 2026

`python3 tools/setup_swi.py --native-root /path/to/swi-prolog-node` validates the
existing checkout using the same pin/runtime/payload checks as the explicit
wrapper. It assembles six browser sources into a content-addressed directory
under ignored `.trinity/` and atomically writes `.trinity/native-swi.json`.
Existing generated payloads are verified and reused; drift is reported rather
than overwritten. No repository fetch, engine installation, permission change
or live-node action occurs.

`demonstrator_startup.pl` centralises selection for `load.pl` (and therefore
`run.pl` and the named deployment entry points), and `Deployment/start_node.pl`.
Pinned mode is the default. It invokes the shared Python validator and then the
existing origin-checking native bootstrap before any node bind. This also works
from a foreign CWD. Missing setup, wrong pins, source/payload drift and mixed
already-loaded native modules fail; no installed pack/local copy is used as an
implicit fallback. Unknown `WP_NATIVE_MODE` values are rejected.

`WP_NATIVE_MODE=legacy` explicitly selects the retained native sources. Existing
asset-root/WASM overrides retain their prior behaviour in that mode. In pinned
mode the generated setup selects this demonstrator and its checked assembled
browser directory. `WP_NATIVE_STATE` can explicitly select another generated
setup JSON file. These are owner startup controls, not Web Prolog predicates.

The existing CI workflow and Dockerfiles set legacy mode explicitly. The minimal
node Dockerfile also copies the central loader; legacy image startup needs no
Python or private checkout. Host `.trinity/` state is excluded from image build
contexts. Neither cross-repository CI nor Docker dependency assembly is switched.
The existing standalone extraction/split-layout tools use a dedicated native
`load.pl` template, so their outputs do not accidentally acquire the
demonstrator's setup dependency.

Verification: [default startup record](verification/swi-default-startup-2026-10-24/REPORT.md).
Regression cases are in `tests/test_default_swi_startup.py`, alongside the existing
pin/extraction tests. Native copies and public URLs remain; duplicate removal,
authenticated CI checkout, deployment assembly, visibility changes and live-node
cutover remain separately reviewable work.

## Pinned native CI integration — 24 October 2026

The existing automatic `CI / test` legacy job remains. A separate
`pinned-native` job is selected only through the workflow's manual
`pinned_native` input. It reads repository and full SHA from the manifest before
checkout; it does not accept a moving native branch or silently fall back to a
retained copy. Checkout credentials are not persisted. An optional existing
`SWI_NODE_READ_TOKEN` secret can supply dependency read access, otherwise checkout
uses the normal workflow token. This batch neither creates that secret nor
changes repository access. While the dependency is private, GitHub execution
remains contingent on an authorized credential; automatic enforcement is deferred.

`tools/ci_pinned_swi.py` supplies the same orchestration locally and on Actions.
It validates the checkout before tests, creates isolated setup/browser outputs,
audits default-loader origins with the retained local library path present,
and runs native LINT/T0/T1_NATIVE/T2/T3_NATIVE/T4_NATIVE/T5 from the dependency's
own driver. T1/T3/T4 integration selections use demonstrator assets. Startup,
pin and runner regressions, cross-repository equivalence and the full WASM tier
remain consumer checks. No complete-node preload is introduced into independent
layer tests. Existing assertions, receive timeouts and the legacy tier command
are preserved; each orchestrated check has the existing CI's 360-second outer
watchdog, with failure aggregation and per-check logs/results.

Startup regression fixtures now accept `PINNED_SWI_TEST_ROOT` so CI's checkout
layout need not mimic sibling directories. Their default path and assertions
are unchanged. No native runtime source or retained implementation copy is edited.

Verification: [pinned CI record](verification/swi-pinned-ci-2026-10-24/REPORT.md).
Repository visibility/access, automatic pinned CI activation, Docker assembly,
duplicate removal and live-node cutover remain separate steps. Installed engines
and n3/n5 are unchanged.

## Maintenance ownership clarified — 24 October 2026

[SWI_NODE_MAINTENANCE.md](SWI_NODE_MAINTENANCE.md) defines where future changes
belong and how to review a full-SHA pin update. Native implementation, native
regressions, pack resources and the shared SXML schema belong in
`swi-prolog-node`. Browser-only sources, UI/tutorial/manual content and dependency
integration remain demonstrator responsibilities. Shared cross-runtime coverage
remains in `trinity-conformance`. Generated payloads are not independently
maintained source copies.

The retained native copies are explicitly transitional. Every applicable native
fix needs a conscious compatibility-mirroring decision while automatic CI and
Docker still use them; a pin update alone does not update those copies. Native
work begins in its own repository, and any compatibility update keeps reviewed
changes and corresponding tests identifiable. No native files or historical
records are removed in this batch.

The demonstrator README now describes consumer setup and ownership; its detailed
transport paragraphs remain available in the retained runtime guide. The stale
claim that repository extraction is the next step has been replaced with current
status. The separate native repository and its pinned commit are unchanged, so
this consumer-documentation edit requires no pin advancement.

Deployment packaging is paused until the normal deployment computer is available.
Automatic pinned CI activation/access, Docker assembly, duplicate removal and
live-node cutover remain separate work. No packaging implementation was made
during the initial inspection on the borrowed computer. Code, installed runtimes
and n3/n5 are unchanged.

### Committed local adoption checkpoint — 25 October 2026

The [commit-pinned adoption batch](verification/committed-adoption-2026-10-25/REPORT.md)
advances the demonstrator's native dependency to the committed answer/output
repairs and selects exact local deployment revisions. Native retained copies
remain available for legacy consumers; this batch does not mirror repaired
native modules into them or remove them. Deployment packaging and public hosting
remain deferred. Local n3 uses the explicit character-list configuration; browser
text reading and the cumulative language baseline remain unchanged.
