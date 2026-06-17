# web-prolog

A Web Prolog implementation for SWI-Prolog: Erlang-style actors, toplevel
query actors (pengines), actor behaviours, and distributed nodes — organized
as independently loadable library layers, with a production node server on
top.

**Status: pre-release.** The layered restructuring is complete through
the node layer: the implementation lives under `prolog/web_prolog/` and
loads as `library(web_prolog)`. The original demonstrator code is kept
under `src/` purely as the frozen conformance reference for the LEGACY
test tier. The migration plan — layer map, hook inventory, conformance
strategy — is in
[docs/LAYERED_REAL_NODE_PLAN.md](docs/LAYERED_REAL_NODE_PLAN.md).

## The layers (target state)

| layer | library | gives you |
|---|---|---|
| 0 | `library(web_prolog/actors)` | spawn/send/receive, links, monitors, registration — a stand-alone actor library; full SWI-Prolog available |
| 1 | `library(web_prolog/isolation)` | per-actor temporary modules, `load_text/1` & friends |
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

## Deploying as a production node

The node **executes untrusted code from clients** — that is the product —
so it is **secure by default**: `auth=private`, and it *refuses to start
world-open* (`auth=open`) unless you set `WP_ACK_PUBLIC=yes`. The
[`Deployment/`](Deployment/) directory is a turn-key bundle with three
paths; the fastest is Docker + Caddy with automatic Let's Encrypt TLS:

```bash
cp Deployment/.env.example Deployment/.env
$EDITOR Deployment/.env          # set SITE_ADDRESS, ACME_EMAIL, WP_AUTH, …
docker compose -f Deployment/compose.yaml --env-file Deployment/.env up -d
curl https://your-node.example.com/healthz      # {"status":"ok"}
```

The full guide — systemd and bare-`swipl` paths, the config-file vs.
environment-variable surfaces (env > file > built-in), operational
endpoints (`/healthz` `/readyz` `/version` `/metrics`, `/admin`), graceful
drain, and the **secure-config checklist** — is in
[Deployment/README.md](Deployment/README.md). SSO-gated deployments are
covered in [Deployment/SSO.md](Deployment/SSO.md).

Validate a configuration without starting the server:

```bash
WP_CHECK=1 WP_PROFILE=actor WP_AUTH=private swipl Deployment/start_node.pl
```

## Tests

```bash
./tools/test.sh          # all tiers, each in a fresh SWI-Prolog process
```

The tier structure (see `tests/tiers/README.md`): the `LEGACY` tier runs the
full demonstrator suite against `src/`; tiers `T0`–`T5` come online as the
corresponding layers are extracted, and each asserts that the layers above
it are *not* loaded.

## Provenance

- [trinity-demonstrator] — the semantic reference this fork preserves
  (full git history included here).
- [swi-web-prolog] — Torbjörn Lager & Jan Wielemaker's earlier
  implementation, whose hook-based layering this project adopts.

[trinity-demonstrator]: https://github.com/torbjornlager/trinity-demonstrator
[swi-web-prolog]: https://github.com/Web-Prolog/swi-web-prolog
