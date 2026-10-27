# Trinity demonstrator

The Web Prolog demonstrator provides the portal, tutorials, shared language
manual, examples, browser runtimes and deployment/integration tooling. Its
native SWI node is supplied by the separate
[`swi-prolog-node`](https://github.com/torbjornlager/swi-prolog-node) repository.
The native SWI pack remains named `web_prolog`, with the existing
`library(web_prolog)` imports.

**Status: pre-release.** The native SWI implementation is maintained only in
`swi-prolog-node`. This repository contains the demonstrator assets, browser-specific
Prolog sources, application examples and integration tests. Local startup, CI and
container builds all require the exact native revision in
[`dependencies/swi-prolog-node.json`](dependencies/swi-prolog-node.json).
There is no in-tree native implementation or legacy startup mode.

## Documentation

The [Web Prolog language manual](web/manual.html) is the single shared API
reference for native SWI, Trealla and SWI-WASM. Runtime differences remain
explicit there. This README covers demonstrator setup and integration.
The [native repository README](https://github.com/torbjornlager/swi-prolog-node/blob/main/README.md)
covers standalone native loading and tests. The [native implementation guide](https://github.com/torbjornlager/swi-prolog-node/blob/main/prolog/web_prolog/README.md)
documents the implementation and its wire protocols. The [SWI-WASM runtime guide](web/README.md) explains browser
coordination, and the [Trealla runtime guide](https://github.com/torbjornlager/trealla-port/blob/main/README.md)
covers that port. Runtime guides do not define separate versions of the language.

The [interoperability baseline 0.1](https://github.com/torbjornlager/trinity-conformance/blob/main/baselines/0.1.md)
and its [coverage matrix](https://github.com/torbjornlager/trinity-conformance/blob/main/reports/2026-10-21-baseline-0.1/COVERAGE.md)
select tested common behavior, including GNU Prolog at ISOBASE level. They keep
unresolved and unmeasured behavior explicit; passing a selection is not complete
profile certification.

## Native dependency architecture

| layer | library | gives you |
|---|---|---|
| 0 | `library(web_prolog/actors)` | spawn/send/receive, links, monitors, registration — a stand-alone actor library; full SWI-Prolog available |
| 1 | `library(web_prolog/isolation)` | per-actor temporary modules, `src_text/1` & friends |
| 2 | `library(web_prolog/toplevel_actors)` | query actors: `'$call'`/`'$next'`/`'$stop'` protocol |
| 2b | server, supervisor, statechart, parallel | reusable actor behaviours |
| 3 | `library(web_prolog/distribution)` + `rpc` | `Id@Node` pids, remote spawn/send/monitor/link, `rpc/2-3`, `promise/3-4`, `yield/2-3` |
| 4 | the node server | ISOBASE `/call`, ISOTOPE sessions, ACTOR WebSocket; auth, profiles, sandbox, limits |
| 5 | `library(web_prolog)` | everything, composed |

Lower layers never depend on higher ones; the connections run through
multifile hooks, following the pattern of [swi-web-prolog]. The shared language
manual defines the language contract; extraction preserves the existing
behaviour. [DEVIATIONS.md](DEVIATIONS.md) retains the restructuring compatibility
record.

## Running

Use a verified threaded SWI build containing the protected-wait fix
[`09b6299`](https://github.com/SWI-Prolog/swipl-devel/commit/09b6299f696574c9230f23e53b1ab041a942b6f3),
as required by the receive adapter. The official **10.1.19** release includes
this fix and passes the native checkpoint recorded below. The official 10.1.18
package predates it; custom builds that report 10.1.18 need source/provenance
verification. Setup also needs Python 3 and Git. Nothing is downloaded or installed by these commands.

From this checkout, prepare an existing native checkout at the revision in
`dependencies/swi-prolog-node.json`:

```bash
python3 tools/setup_swi.py --native-root /path/to/swi-prolog-node
swipl load.pl
```

Setup validates the pin and assembles browser sources under ignored `.trinity/`.
`load.pl`, `run.pl` and `Deployment/start_node.pl` share this selection and
revalidate setup before node startup, including from another working directory.
Missing setup, changed native files or payload drift fail without a local-copy
fallback. Rerun setup after updating the pin or browser sources.

`WP_NATIVE_STATE` can name an alternate generated setup JSON file. Setup validates
the exact native revision and clean runtime sources, and assembles browser payloads
using the dependency's shared SXML schema. Missing setup or source/payload drift
fails before a node starts. `WP_NATIVE_MODE=legacy` is rejected.

If you need a fresh checkout at the recorded pin, fetch it explicitly before setup:

```bash
python3 tools/fetch_swi.py --destination .trinity/native
python3 tools/setup_swi.py --native-root .trinity/native
swipl load.pl
```

Fetching requires read access to the native repository. An existing checkout is
never overwritten; using a separate checkout avoids changing your development branch.

```prolog
?- node(3060).
```

Or load layers selectively:

```prolog
?- use_module(library(web_prolog/actors)).   % just actors, full SWI
?- use_module(library(web_prolog/rpc)).      % rpc/promise/yield client
?- use_module(library(web_prolog)).          % everything
```

Then try:

- the shell at <http://localhost:3060/portal>
- the stateless API:
  `http://localhost:3060/call?goal=member(X,[a,b])&format=prolog`

### Continuous integration

Both `CI / test` and `CI / wasm` check out the exact native dependency on pushes,
pull requests and manual runs. The main job runs the dependency's native and
external-asset integration tiers, this repository's tiered regression suite,
startup/pin/packaging regressions, a module-origin audit and browser checks. The
separate WASM job provides independent browser-runtime feedback. Both use the
checksum-pinned official SWI-Prolog 10.1.19 release and Node.js 22.

Checks run in fresh processes with bounded process-group watchdogs. Logs and results
are uploaded even after failure. A private native repository requires the existing
owner-provided `SWI_NODE_READ_TOKEN` Actions secret; the default workflow token does
not grant cross-repository access. A failed dependency checkout fails CI without
substituting another implementation.

Run the complete CI boundary locally with an existing pinned checkout:

```bash
python3 tools/ci_pinned_swi.py --native-root /path/to/pinned/swi-prolog-node \
  --swipl /path/to/verified/swipl --output /fresh/path/pinned-ci-results
```

The output directory must be new. The runner records setup there and leaves the
ordinary local setup untouched. It does not fetch repositories or restart live nodes.
Node.js must be on PATH for browser checks.

## Demonstrator asset locations

Startup configures `WP_ASSET_ROOT` as this demonstrator checkout and
`WP_WASM_SOURCE_DIR` as the validated payload directory from setup. The five
browser-specific Prolog sources remain under `prolog/web_prolog/wasm/`; the sixth
file, `sxml_schema.pl`, is copied from the pinned native package during assembly.
No second native schema is maintained here. Portal, tutorial, manual, example and
browser-runtime URLs remain unchanged.

## Deploying as a production node

The node **executes untrusted code from clients** — that is the product —
so it is **secure by default**: `auth=private`, and it *refuses to start
world-open* (`auth=open`) unless you set `WP_ACK_PUBLIC=yes`. The
[`Deployment/`](Deployment/) directory contains the Docker + Caddy stack
used for the repository's `elfenbenstornet.se` nodes:

```bash
cp Deployment/.env.n5-sso.example Deployment/.env
$EDITOR Deployment/.env          # set OAuth credentials and registration policy
docker compose -f Deployment/compose.yaml --env-file Deployment/.env up -d --build
curl https://n5.elfenbenstornet.se/healthz      # {"status":"ok"}
```

The full topology, environment setup, operational commands, and SSO-gated
`n5` configuration are documented in
[Deployment/README.md](Deployment/README.md).
That guide also contains an opt-in, immediately reversible Trealla N5
override for private interoperability testing.

Native routing and transport details are recorded in the
[runtime integration notes](https://github.com/torbjornlager/swi-prolog-node/blob/main/prolog/web_prolog/README.md#native-integration-notes).

Validate a configuration without starting the server:

```bash
WP_CHECK=1 WP_PROFILE=actor WP_AUTH=private swipl Deployment/start_node.pl
```

## Maintenance and tests

Native implementation fixes and their regression tests belong in
`swi-prolog-node`; demonstrator assets, browser changes and integration tests belong
here. Update the dependency pin deliberately after testing the selected revision,
then rerun setup. See [native maintenance](docs/SWI_NODE_MAINTENANCE.md).

```bash
SWIPL=/path/to/verified/swipl ./tools/test.sh
```

Tiers `T0`–`T5` exercise the external implementation in fresh processes without
preloading upper layers. `LINT` checks layering in the pinned package. `WASM` checks
browser statecharts, Worker/coordinator bridges and real-engine semantics. The
`T1_NATIVE`, `T3_NATIVE`, `T4_NATIVE` and corresponding `_INTEGRATION` selections
remain available. The two tests requiring a colocated native/browser tree were
retired; explicit asset relocation and missing-asset checks remain.

## Provenance

- [trinity-demonstrator] — this repository retains the pre-extraction
  implementation history and migration records.
- [swi-web-prolog] — Torbjörn Lager & Jan Wielemaker's earlier
  implementation, whose hook-based layering this project adopts.

[trinity-demonstrator]: https://github.com/torbjornlager/trinity-demonstrator
[swi-web-prolog]: https://github.com/Web-Prolog/swi-web-prolog


### Boolean option boundary

Language Boolean options require Prolog atoms `true` or `false`, not numbers,
strings, character lists or JSON wrapper terms. Native SWI and Trealla and both
browser runtimes validate asynchronous `toplevel_call/3` `once/1` values before
dispatch, including later duplicates. The browser bridge's internal conversion
of encoded Prolog atoms remains transport plumbing. HTTP query text and genuine
JSON Booleans retain their endpoint decoding. See the shared manual's
[option validation](web/manual.html#sec:option-validation).

The native fix belongs to `swi-prolog-node`. The demonstrator consumes native
changes through reviewed dependency pin updates.

### URI representation boundary

URI and node-URL inputs use atoms canonically; supported text forms and explicit
`Host:Port` shorthand are normalised at API boundaries. The [shared URI contract](web/manual.html#sec:uri-values)
records the runtime differences and unchanged resolution/fetch restrictions.
Browser bridges preserve source ordering and validate representations before
fetching or dispatch. Native implementation and validation live in
`swi-prolog-node`; updating source here does not update live nodes.

### Commit-pinned local development nodes

The [25 October adoption record](docs/verification/committed-adoption-2026-10-25/REPORT.md)
records the selected native SWI, Trealla and demonstrator commits and the
verified local n3/n5 launchers. Local n3 explicitly selects character-list
reading; normal package defaults and browser text semantics are unchanged.
Startup rejects source drift, and the previous frozen launchers remain available
for rollback. Follow [native maintenance](docs/SWI_NODE_MAINTENANCE.md) for future
fixes and explicit pin updates; do not edit the deployment checkouts.
