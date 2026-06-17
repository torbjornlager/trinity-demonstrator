# Test tiers

Each tier is run by `tools/test.sh` in a **fresh SWI-Prolog process** and
corresponds to one layer combination from
[`docs/LAYERED_REAL_NODE_PLAN.md`](../../docs/LAYERED_REAL_NODE_PLAN.md) §4.

The demonstrator's full suite now lives across these tiers (its own test
files copied verbatim into `behaviours/` and `node/`, plus the lower-layer
cases adapted into `t0`–`t2`). The former `LEGACY` tier — the demonstrator
suite run against an in-tree `src/` copy — was retired once `T0`–`T5`
subsumed it, and `src/` was removed.

| tier | loads | runs | layer-honesty assertion |
|---|---|---|---|
| T0 | `actors` only | actor tests not needing source options | no isolation/toplevel/distribution/node modules loaded |
| T1 | + `isolation` + minimal glue | module prep, `load_text/1` & friends | no toplevel/distribution/node |
| T2 | + `toplevel_actors` | toplevel actor tests | no distribution/node |
| T3 | + behaviours | server/supervisor/statechart/parallel | no distribution/node |
| T4 | + `distribution` + node | node_tests, multi-node harness, golden responses | — |
| T5 | new node ↔ unmodified trinity-demonstrator | wire-level interop both directions | — |

Contract for a tier file (`tN_*.pl`):

- export `run_tier/0`, which runs the tier's plunit suites and **fails**
  (nonzero exit) on any failure;
- begin by asserting layer honesty, e.g.
  `assertion(\+ current_module(distribution))` — these assertions are the
  mechanical guarantee that lower layers stay stand-alone;
- pid-shape note: below T4, pids are opaque (plan §2.4) — tier tests must
  not assert `integer(Pid)` or `_@_` forms.

Tier files are created by the phase that brings their layer into
existence; a missing file is reported by the runner as "pending", not as
a failure.
