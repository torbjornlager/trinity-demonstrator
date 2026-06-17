# Notes for Claude

## What this project is

A production Web Prolog node for SWI-Prolog, forked from the
trinity-demonstrator and being restructured into hook-connected layers.
The plan is `docs/LAYERED_REAL_NODE_PLAN.md` — read it before structural
work.

## Hard rules

- **Semantics freeze.** Web Prolog syntax and semantics must match the
  trinity-demonstrator exactly. Any intentional observable deviation goes
  in `DEVIATIONS.md` (which must stay empty through v1). The demonstrator's
  test suite is the spec — it now lives relocated across the `T0`–`T5`
  tiers under `tests/tiers/` (the in-tree `src/` copy and its LEGACY tier
  were removed once the tiers fully subsumed them; the live demonstrator
  checkout remains the interop peer for T5).
- **No upward imports.** Layer N may only import layers ≤ N
  (actors < isolation < toplevel/behaviours < distribution < node <
  umbrella). Cross-layer connections go through multifile hooks, declared
  in the lower layer, with the glue defined in the umbrella.
- **No integer pids below distribution.** Layer-0 pids are opaque local
  handles behind `hook_make_pid/2` / `hook_resolve_pid/2`; integers and
  `Id@Node` arrive with `distribution.pl` (plan §2.4).
- **Relocation and behavior changes never share a commit.** Code moves
  verbatim; hook indirections are introduced in their own commits.

## Building and testing

- Run the suite with `./tools/test.sh` (tiered; each tier is a fresh
  process). Tiers `T0`–`T5` carry the full demonstrator suite against the
  layered `prolog/web_prolog/` modules (the demonstrator's own test files
  copied verbatim into `tests/tiers/behaviours/` and `tests/tiers/node/`,
  plus the lower-layer cases adapted in `t0`–`t2`). `LINT` checks layering.
- On this development machine, `~/bin/swipl` shadows a broken ancient
  build; use `SWIPL=/Applications/SWI-Prolog.app/Contents/MacOS/swipl`.

## Relation to other checkouts

- `/Users/lager/trinity-demonstrator` is the upstream reference (git
  remote `demonstrator` here). Never edit it as part of work in this
  repo; it is also the interop peer for tier T5.
