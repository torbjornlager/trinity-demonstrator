# What the Discovery Hub reads from each node

The hub seed holds addresses only. Everything a hub card shows comes from
the node's own `GET /node_info`. Status, latency and last-seen time come
from the hub's probes.

| Field | Shown as | Limit |
|---|---|---|
| `implementation` | engine label, e.g. `SWI-Prolog` | 40 characters |
| `version` | after the engine label | 40 characters |
| `description` | one line on the card; optional | 160 characters |
| `profile`, `auth` | badges, plus the profile's routes | — |
| `provides`, `services` | capability lists and filters | — |
| `self_contained` | portability badge | — |

Whitespace is collapsed and longer text is cut. A missing field shows as
nothing. A description should add only what the card cannot already show.

## Where each node gets these fields

| Node | Source | Description set in |
|---|---|---|
| N0 | `swi-prolog-node` (`description/1` node option) | `WP_DESCRIPTION` in the hub compose files |
| N1–N4 | `swi-prolog-node` | `description(...)` in `Deployment/start_n1.pl` … `start_n4.pl` |
| N5 | `trealla-port` (`description/1` node option) | `WP_DESCRIPTION` in `compose.trealla-n5.yaml` |
| N6 | `Deployment/n6_adapter.py` | `N6_DESCRIPTION` (default in the adapter) |
| N7 | `eclipse-node` `isotope_http.py` | `N7_DESCRIPTION` (default in the adapter, public mode only) |

SWI and Trealla report their engine version from `version_data`. A RELATION
node (N0) advertises exactly its relation patterns as `provides`. N7 reports
its shared database's export list, `self_contained`, and `ECLiPSe Prolog`.

## Release order

1. Release `swi-prolog-node`, then update `dependencies/swi-prolog-node.json`.
   (An older pinned node accepts `description(...)` and ignores it.)
2. Release `trealla-port` and update `dependencies/trealla-port.json`
   (older Trealla nodes ignore `WP_DESCRIPTION` too).
3. Release the N7 adapter from `eclipse-node`.
4. Rebuild N0–N6 from the demonstrator, then check every hub card.

Until a node reports these fields, its card shows no engine label or
description.
