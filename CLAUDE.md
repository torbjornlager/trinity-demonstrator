# Notes for Claude

## What this project is

This repo **is** the trinity-demonstrator (`origin` →
github.com/torbjornlager/trinity-demonstrator): a production Web Prolog
node for SWI-Prolog, restructured in place from its original `src/`-based
form into hook-connected layers under `prolog/web_prolog/`. The plan is
`docs/LAYERED_REAL_NODE_PLAN.md` — read it before structural work.

## Hard rules

- **Semantics freeze.** Web Prolog syntax and semantics must match the
  pre-layering demonstrator (the `demonstrator-peer` git tag) exactly.
  Any intentional observable deviation goes in `DEVIATIONS.md`. The
  demonstrator's test suite is the spec — it now lives relocated across
  the `T0`–`T5` tiers under `tests/tiers/` (the in-tree `src/` copy and
  its LEGACY tier were removed once the tiers fully subsumed them; the
  original `src/` tree, preserved under the `demonstrator-peer` tag, is
  materialized into a temp dir as the interop peer for T5 — there is no
  separate live demonstrator checkout).
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

- This working directory `/Users/lager/trinity-demonstrator` **is** the
  trinity-demonstrator (`origin` →
  github.com/torbjornlager/trinity-demonstrator) — the live node itself,
  the same code that runs on N3–N5 and ships the SWI-WASM model under
  `web/`. There is no separate "upstream" checkout to leave untouched and
  no `demonstrator` git remote; editing here **is** editing the
  demonstrator.
- The semantics-freeze reference is the `demonstrator-peer` git **tag**
  (the original pre-layering `src/` tree), which T5 extracts into a
  throwaway temp dir as the interop peer.
- A sibling `/Users/lager/web-prolog` checkout exists but is **superseded**:
  all work consolidated into this repo. The layered node, the discovery-hub
  plan, and `LAYERED_REAL_NODE_PLAN.md` / `DISCOVERY_HUB_PLAN.md` all live
  here under `docs/`. Don't send new work to `web-prolog`.
