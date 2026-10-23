# web-prolog

A Web Prolog implementation for SWI-Prolog: Erlang-style actors, toplevel
query actors (pengines), actor behaviours, and distributed nodes — organized
as independently loadable library layers, with a production node server on
top.

**Status: pre-release.** The layered restructuring is complete through
the node layer: the implementation lives under `prolog/web_prolog/` and
loads as `library(web_prolog)`. The demonstrator's conformance suite has
been fully relocated into the `T0`–`T5` tiers under `tests/tiers/`, so the
original in-tree `src/` copy has been removed. The migration plan — layer
map, hook inventory, conformance strategy — is in
[docs/LAYERED_REAL_NODE_PLAN.md](docs/LAYERED_REAL_NODE_PLAN.md).

## Documentation

The [Web Prolog language manual](web/manual.html) is the single shared API
reference for native SWI, Trealla and SWI-WASM. Runtime differences remain
explicit there; this README describes the native SWI implementation and setup.
The [layered implementation guide](prolog/web_prolog/README.md) covers internals
and wire protocols. The [SWI-WASM runtime guide](web/README.md) explains browser
coordination, and the [Trealla runtime guide](https://github.com/torbjornlager/trealla-port/blob/main/README.md)
covers that port. Runtime guides do not define separate versions of the language.

The [interoperability baseline 0.1](https://github.com/torbjornlager/trinity-conformance/blob/main/baselines/0.1.md)
and its [coverage matrix](https://github.com/torbjornlager/trinity-conformance/blob/main/reports/2026-10-21-baseline-0.1/COVERAGE.md)
select tested common behavior, including GNU Prolog at ISOBASE level. They keep
unresolved and unmeasured behavior explicit; passing a selection is not complete
profile certification.

## The layers (target state)

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
multifile hooks, following the pattern of [swi-web-prolog]. Web Prolog
syntax and semantics are frozen to the trinity-demonstrator's — see
[DEVIATIONS.md](DEVIATIONS.md), which is expected to stay empty.

## Running

Requires SWI-Prolog ≥ 9.x with threads.

```bash
swipl load.pl
```

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

## Demonstrator asset locations

The native node can serve a demonstrator tree from a separate location while
keeping the existing portal, tutorial, manual, example and browser-runtime URLs:

```bash
WP_ASSET_ROOT=/path/to/trinity-demonstrator swipl load.pl
```

`WP_WASM_SOURCE_DIR` optionally selects the directory of the six browser Prolog
sources. Without that override, an explicit asset root uses its current
`prolog/web_prolog/wasm/` layout. With neither variable set, all lookups retain
the existing checkout defaults. Explicit locations do not fall back to another
checkout when a file is missing. These are process-wide operator settings;
all nodes in one SWI process share them.

The [native extraction map](docs/SWI_NODE_EXTRACTION_MAP.md) records file
ownership, dependencies, configuration settings and the remaining extraction
steps. No repository separation has been performed yet.

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

Outgoing remote toplevel calls remove the caller's outer module qualification
before serialization: private actor modules belong to the sending node. Nested
goal qualifications, options and goal/template variable sharing are preserved.
This applies to asynchronous and synchronous calls; local calls are unchanged.

Native SWI and Trealla prefer the optional WebSocket subprotocol
`web-prolog-sync-spawn-v1`, which guarantees both correlated toplevel replies
and request IDs on spawn successes and failures. With that selection, the
client accepts only the current spawn's ID; untagged command errors go to the
`distribution(remote)` debug topic and `distribution:hook_event/1` as
`remote_transport_error` events. They cannot become a later spawn failure.
The older `web-prolog-sync-v1` offer and unnegotiated peers retain serialized
legacy spawning; untagged errors on those connections remain ambiguous.
Connection loss still reports an unknown remote startup outcome. This does
not implement Trealla's missing `lineage_close` handling.

Validate a configuration without starting the server:

```bash
WP_CHECK=1 WP_PROFILE=actor WP_AUTH=private swipl Deployment/start_node.pl
```

## Tests

```bash
./tools/test.sh          # all tiers, each in a fresh SWI-Prolog process
```

The tier structure (see `tests/tiers/README.md`): tiers `T0`–`T5` carry the
full demonstrator suite against the layered modules, one layer per tier,
and each asserts that the layers above it are *not* loaded. `LINT` checks
that imports only point downward.

## Provenance

- [trinity-demonstrator] — the semantic reference this fork preserves
  (full git history included here).
- [swi-web-prolog] — Torbjörn Lager & Jan Wielemaker's earlier
  implementation, whose hook-based layering this project adopts.

[trinity-demonstrator]: https://github.com/torbjornlager/trinity-demonstrator
[swi-web-prolog]: https://github.com/Web-Prolog/swi-web-prolog
