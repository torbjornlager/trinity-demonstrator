# Native SWI node extraction: files, dependencies and first seam

Status: first preparation batch, 23 October 2026. No repository or source files
have been moved. Native runtime behavior and HTTP URLs are preserved.

## Ownership map

| Current paths | Responsibility | Intended home |
| --- | --- | --- |
| `prolog/web_prolog.pl`, native `prolog/web_prolog/*.pl` | Native SWI library: actors, isolation, behaviours, distribution, HTTP/WebSocket server, policy and administration backend | SWI implementation repository |
| `prolog/web_prolog/sxml-0.2.dtd` | Grammar served at `/sxml-0.2.dtd`; shipped beside the node implementation | Retain with the runtime for the first extraction; preserve one authoritative schema source |
| `prolog/web_prolog/shared_db.pl` | Default node shared database, loaded by `node_startup_options.pl` | Retain as a runtime-shipped default initially; distinguish its example content from the shared-db mechanism |
| `web/*.html`, `web/vendor/`, `web/tabler.min.css`, `img/` | Portal, tutorials, shared language manual, browser editor, discovery/admin presentation, vendored browser dependencies | Demonstrator repository; native administration backend remains in the runtime |
| `web/swi_wasm_actor_worker.js`, `web/swipl-bundle.js`, browser code embedded in `web/demonstrator.html` | Worker and main-thread browser runtimes and their host integration | Demonstrator repository initially |
| `prolog/web_prolog/wasm/*.pl` | Six browser Prolog sources, fetched through `/wasm/`; currently physically nested beneath native code | Demonstrator/browser ownership; decide physical move in a later batch |
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

## Remaining dependencies to resolve before physical extraction

1. **Lower-layer example convenience helper.**
   `statechart_actor:interpret_example/1` still resolves
   `../../examples/statecharts` directly. It cannot import layer-4 node assets.
   Decide whether to supply its example path through a lower-layer mechanism or
   make it a demonstrator helper. Ordinary statechart execution and URI fetching
   are unchanged by this batch.
2. **WASM ownership and equivalence checks.**
   Keep the two browser runtimes and six Prolog files together initially.
   `tools/check_statechart_wasm_equivalence.py` currently reads both native and
   WASM paths from this checkout; later CI must name the pinned native source.
3. **Mixed tests and historical peer.**
   T4's large `node/node_tests.pl` includes frontend content assertions and direct
   file reads. Preserve them as integration tests while making native tests
   runnable without a demonstrator checkout. T5 materializes `demonstrator-peer`
   using Git history; retain that tag/history or an explicitly pinned fixture.
   Trealla interop and conformance launchers also refer to sibling native paths.
4. **Packaging and entry points.**
   Preserve `library(web_prolog)` and selective layer loads. `debug.pl` expects
   `../../load.pl`; `node_version.pl` discovers `../../pack.pl` and `.git`.
   These are native package-layout assumptions rather than frontend assets,
   but extraction and source archives must retain meaningful version identity.
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

The next batch can extract native sources after these ownership decisions, with
no language repair mixed into the move. Verification for this first seam is in
`docs/verification/configurable-assets-2026-10-23/`.
