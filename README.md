# Trinity demonstrator

The Web Prolog demonstrator provides the portal, tutorials, shared language
manual, examples, browser runtimes and deployment/integration tooling. Its
native SWI node is supplied by the separate
[`swi-prolog-node`](https://github.com/torbjornlager/swi-prolog-node) repository.
The native SWI pack remains named `web_prolog`, with the existing
`library(web_prolog)` imports.

**Status: pre-release.** The layered restructuring is complete through
the node layer. Normal local startup loads the pinned `swi-prolog-node`
dependency as `library(web_prolog)`; `prolog/web_prolog/` remains as an explicit
legacy/test copy during extraction. The demonstrator's conformance suite has
been fully relocated into the `T0`–`T5` tiers under `tests/tiers/`, so the
original in-tree `src/` copy has been removed. The migration plan — layer
map, hook inventory, conformance strategy — is in
[docs/LAYERED_REAL_NODE_PLAN.md](docs/LAYERED_REAL_NODE_PLAN.md).

## Documentation

The [Web Prolog language manual](web/manual.html) is the single shared API
reference for native SWI, Trealla and SWI-WASM. Runtime differences remain
explicit there. This README covers demonstrator setup and integration.
The [native repository README](https://github.com/torbjornlager/swi-prolog-node/blob/main/README.md)
covers standalone native loading and tests. The retained
[layered implementation guide](prolog/web_prolog/README.md) documents the
compatibility copy and its wire protocols. The [SWI-WASM runtime guide](web/README.md) explains browser
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
as required by the receive adapter. The version number alone is insufficient;
the official macOS 10.1.18 package predates that fix. Setup also needs Python 3
and Git. Nothing is downloaded or installed by these commands.

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

To explicitly use the retained native copies without setup:

```bash
WP_NATIVE_MODE=legacy swipl load.pl
```

`WP_NATIVE_STATE` can name an alternate generated setup JSON file. Automatic CI
and the existing Dockerfiles retain legacy mode. CI also provides an explicit
pinned-dependency job, described below. No running node or durable launcher is
switched by setup.

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

### Pinned native CI checks

The `CI` workflow preserves its existing push/pull-request legacy job. Its
manual **Run workflow** form additionally offers `pinned_native`, defaulting to
false. Selecting it checks out the exact SHA from
`dependencies/swi-prolog-node.json`, then runs native tiers from that checkout,
external-asset integration tiers, startup/pin regressions, a loaded-module origin
audit, browser equivalence and the WASM tier. Each check retains a 360-second
outer watchdog; failures are recorded while subsequent checks continue. The job
uploads logs, provenance and individual results even after check failures.

The native repository is currently private. Its checkout requires an
owner-provided `SWI_NODE_READ_TOKEN` Actions secret with read access to that
repository; the normal workflow token is used when no such secret exists and
does not itself grant cross-repository access. No credential, permission or
repository visibility is configured by this integration. Without access, the
selected job fails at checkout; it never substitutes retained sources. The job
is not yet an automatic cross-repository acceptance gate. The installed engine
must also meet the receive-adapter prerequisite stated above.

To run the same checks locally against an existing checkout and verified engine:

```bash
python3 tools/ci_pinned_swi.py --native-root /path/to/swi-prolog-node \
  --swipl /path/to/verified/swipl --output /fresh/path/pinned-ci-results
```

The output directory must be new. Setup and assembled browser payloads live
inside it, leaving the ordinary `.trinity/native-swi.json` untouched. Node.js
must be on PATH for browser checks. This runner never fetches repositories,
installs engines or restarts live nodes.

## Demonstrator asset locations

The native node can serve a demonstrator tree from a separate location while
keeping the existing portal, tutorial, manual, example and browser-runtime URLs:

```bash
WP_NATIVE_MODE=legacy WP_ASSET_ROOT=/path/to/trinity-demonstrator swipl load.pl
```

In legacy mode, `WP_WASM_SOURCE_DIR` optionally selects the directory of the six browser Prolog
sources. Pinned mode instead uses this demonstrator and the validated assembled
payload directory recorded by setup. Without that override, an explicit asset root uses its current
`prolog/web_prolog/wasm/` layout. With neither variable set, all lookups retain
the existing checkout defaults. Explicit locations do not fall back to another
checkout when a file is missing. These are process-wide operator settings;
all nodes in one SWI process share them.

The [native extraction map](docs/SWI_NODE_EXTRACTION_MAP.md) records file
ownership, dependencies, configuration settings and the remaining extraction
steps. The native repository is privately published; default local startup now
uses its pinned revision, while duplicate removal and deployment migration remain
separate steps.

The split-layout rehearsal in `tools/check_swi_split_layout.py` builds disposable
native and demonstrator-asset trees, then checks native APIs, external frontend
integration, selection coverage and the original full T4. See the extraction
map for its file manifest and commands. `tools/test.sh` additionally accepts
`T1_NATIVE`, `T3_NATIVE`, `T4_NATIVE`, their `_INTEGRATION` counterparts, and
`T4_LEGACY_LAYOUT`; ordinary full-tier invocations retain all existing tests.

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

Native routing and transport details are recorded in the retained
[runtime integration notes](prolog/web_prolog/README.md#native-integration-notes).

Validate a configuration without starting the server:

```bash
WP_CHECK=1 WP_PROFILE=actor WP_AUTH=private swipl Deployment/start_node.pl
```

## Maintenance and tests

For future fixes, dependency updates and compatibility-copy handling, follow
[the native maintenance guide](docs/SWI_NODE_MAINTENANCE.md). Native implementation
changes and native regression tests belong in `swi-prolog-node`; demonstrator
assets, browser changes and consumer integration tests belong here. Pinning a
new native revision does not update the retained legacy copies.

The pinned integration runner above tests the dependency. To deliberately test
the retained compatibility implementation:

```bash
WP_NATIVE_MODE=legacy ./tools/test.sh  # all tiers in fresh SWI-Prolog processes
```

The retained tier structure (see [tests/tiers/README.md](tests/tiers/README.md)): tiers `T0`–`T5` carry the
full demonstrator suite against the layered modules, one layer per tier,
and each asserts that the layers above it are *not* loaded. `LINT` checks
that imports only point downward.

## Provenance

- [trinity-demonstrator] — this repository retains the pre-extraction
  implementation history and migration records.
- [swi-web-prolog] — Torbjörn Lager & Jan Wielemaker's earlier
  implementation, whose hook-based layering this project adopts.

[trinity-demonstrator]: https://github.com/torbjornlager/trinity-demonstrator
[swi-web-prolog]: https://github.com/Web-Prolog/swi-web-prolog


The native repository has already been extracted. See
[the extraction map](docs/SWI_NODE_EXTRACTION_MAP.md) for current ownership,
completed integration checks and historical rehearsal records. Deployment
packaging is paused until the normal deployment computer is available; no
implementation copies are removed during this transition.

### Boolean option boundary

Language Boolean options require Prolog atoms `true` or `false`, not numbers,
strings, character lists or JSON wrapper terms. Native SWI and Trealla and both
browser runtimes validate asynchronous `toplevel_call/3` `once/1` values before
dispatch, including later duplicates. The browser bridge's internal conversion
of encoded Prolog atoms remains transport plumbing. HTTP query text and genuine
JSON Booleans retain their endpoint decoding. See the shared manual's
[option validation](web/manual.html#sec:option-validation).

The native fix belongs to `swi-prolog-node`; this batch mirrors it explicitly
in the retained legacy source for compatibility tests. The dependency pin and
installed/live runtimes are not updated by these source changes.

### URI representation boundary

URI and node-URL inputs use atoms canonically; supported text forms and explicit
`Host:Port` shorthand are normalised at API boundaries. The [shared URI contract](web/manual.html#sec:uri-values)
records the runtime differences and unchanged resolution/fetch restrictions.
Browser bridges preserve source ordering and validate representations before
fetching or dispatch. Native-owned checks are mirrored in the retained legacy
source; this does not promote the native dependency pin or update live nodes.

### Commit-pinned local development nodes

The [25 October adoption record](docs/verification/committed-adoption-2026-10-25/REPORT.md)
records the selected native SWI, Trealla and demonstrator commits and the
verified local n3/n5 launchers. Local n3 explicitly selects character-list
reading; normal package defaults and browser text semantics are unchanged.
Startup rejects source drift, and the previous frozen launchers remain available
for rollback. Follow [native maintenance](docs/SWI_NODE_MAINTENANCE.md) for future
fixes and explicit pin updates; do not edit the deployment checkouts.
