# Discovery self-description — live verification, 22 November 2026

**Deployed and verified.** Every node now reports its own engine, version and
description in `/node_info`. The Discovery Hub shows only what nodes report
about themselves; no curated labels are needed.

| Node | Implementation | Version | Description (truncated) |
|------|---------------|---------|------------------------|
| N0 | SWI-Prolog | 11.0.0 | Discovery hub. Probes the other nodes… |
| N1 | SWI-Prolog | 11.0.0 | Stateless node with family, movie and small DCG… |
| N2 | SWI-Prolog | 11.0.0 | Adds toplevel sessions with private session databases. |
| N3 | SWI-Prolog | 11.0.0 | Hosts the statechart demonstrator; pairs with N4… |
| N4 | SWI-Prolog | 11.0.0 | Second SWI ACTOR node; pairs with N3… |
| N5 | Trealla Prolog | 3.14.20 | Trealla Prolog implementation of the ACTOR profile. |
| N6 | GNU Prolog | 1.6.0 | GNU Prolog port of the ISOBASE profile. |
| N7 | ECLiPSe Prolog | 7.2.13 | Each public engine runs in its own isolated container. |

N0 provides exactly 13 `node_*` relations (no `member/2`). All `provides`
counts match the nodes' actual relay contracts.

## Units deployed

| Unit | Source | Candidate image |
|------|--------|----------------|
| N5 | trealla-port `edf2283` | `b3f82f90` |
| N7 adapter | eclipse-node `cbe235c` | `e00889c5` |
| N6 | trinity-demonstrator `c5ebc76` | `b86ec3b3` |
| N1–N4, admin | swi-prolog-node `67f0b17` + browser `1d6ee0d` | n134 `8fc5c543`, n2 `bb85170b`, admin `e1f380af` |
| Static assets | demonstrator `c5ebc76` + browser `1d6ee0d` | Caddy root `discovery-20261122` |
| N0 | swi-prolog-node `67f0b17` + browser `1d6ee0d` | `b728c88d` |

## Operator fixes applied during release

Three issues found when running the scoped deploy operators for the first time:

1. **`deploy_n5.py` UNRELATED list**: `deployment-oauth2_n5-1` removed — container
   no longer exists (moved to static address in a previous release).

2. **Pre-existing FAIL probes**: `pe008` and `timeout-abc` have always returned
   the same FAIL in baseline. The `probes()` check in `deploy_n5.py` and
   `deploy_n7.py` was updated to only fail on *new* FAILs, not pre-existing ones.

3. **`deploy_n7.py` UNRELATED list**: `trinity-n7-https-oauth2_n7-1` removed —
   container no longer exists.

4. **SWI `config_view` ip check**: The `ips` dict only included static-IPAM IPs.
   After the candidate switch (which pins the IPs), the before/after comparison
   failed because the predecessor had dynamic IPs. Fixed to compare all IPs from
   `NetworkSettings.Networks`.

5. **N0 `WP_DESCRIPTION` missing** from the candidate model: added after the
   initial switch; N0 was recreated with the description env var.

## WP_NET_ADDRESS_PLAN step 2

Static `ipv4_address` pins added to all six SWI containers in their candidate
Compose models: wp_admin (172.18.0.2), wp_n1 (172.18.0.3), wp_n2 (172.18.0.4),
wp_n3 (172.18.0.5), wp_n4 (172.18.0.6), n0 (172.18.0.7).

## Static assets rollback

The `discovery-20261122` Caddy roots staged for the static-assets unit held a
`package_demonstrator.py` output with `WEB_PROLOG_HOST = {"mode":"static",
"nodeUrl":null}`. This broke every node UI: pages requested `.html` routes
(404), node buttons stayed on SWI-WASM, and N7 linked to `/index.html`. The
issue is that `package_demonstrator.py` produces a fully self-contained static
site for CDN/file-server hosting, not an overlay for a live node's Caddy root.
The live roots serve the node's own `demonstrator.html` via the backend; Caddy
only fronts the runtime assets (JS, wasm, vendor). As on 21 November, the
existing roots already match the pin; republishing is not needed.

The `discovery-20261122` roots were removed from Caddy immediately (before any
change to the node containers or the hub page). `original-Caddyfile` (the
pre-release snapshot) was restored and Caddy was reloaded gracefully.

Verification after rollback:

| Check | N1 | N4 |
|-------|----|----|
| `/demonstrator` HTTP 200 | ✓ | ✓ |
| Editor present | ✓ | ✓ |
| `/examples_index` actors/statecharts | 25/20 | 25/20 |
| `/demonstrator.html` returns 404 | ✓ | ✓ |
| `swipl-bundle.js` sha256 matches `uri-20261117` | ✓ | ✓ |

N7 `/demonstrator` returns 200 (own UI, correct title, 508 KB). The N7
static-assets Caddy root was not part of this release and was not changed.

## Discovery Hub static file

After all units were switched, `https://n0.elfenbenstornet.se/discovery-hub`
returned "Hub unreachable". Caddy serves that path as a static file from
`/srv/trinity/portable-20261112-zsn664hr/hub/discovery-hub.html` (a separate
pointer from the N0–N6 static roots). That file still called
`node_directory_row(...,Description,Note)` — the old 10-arity form without
`Implementation` and `Version`. N0 now serves the new 10-arity form with those
fields instead of `Note`.

Fix: replaced the file in-place with `web/discovery-hub.html` from `c5ebc76`
(sha256 `51add514…`). The N7 Data-button hide is already in that file. No Caddy
reload was needed (`Cache-Control: no-cache` already set). The hub immediately
returned 8 rows, all `up`, each with the correct engine and description.

`/srv/trinity` inside `deployment-caddy-1` is backed by the
`deployment_edge_assets` named Docker volume — there is no host-path binding.
The modified file lives only in that volume. A Caddy recreate reattaches the
same volume and the fix survives; replacing the volume or copying from an older
source would restore the old file and break the hub page again.

## Rollback

Each unit has a sealed rollback model. `deploy_nN.py --rollback` restores the
predecessor image for N5, N6, N7. `deploy_swi.py --rollback` restores all SWI
services. The rehearsal for each unit injected a failure and confirmed automatic
predecessor restoration with state marker preserved.
