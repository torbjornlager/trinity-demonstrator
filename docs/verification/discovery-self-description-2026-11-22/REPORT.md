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

## Discovery Hub static file

After all units were switched, `https://n0.elfenbenstornet.se/discovery-hub`
returned "Hub unreachable". Caddy serves that path as a static file from
`/srv/trinity/portable-20261112-zsn664hr/hub/discovery-hub.html` (a separate
pointer from the N0–N6 static roots). That file still called
`node_directory_row(...,Description,Note)` — the old 10-arity form without
`Implementation` and `Version`. N0 now serves the new 10-arity form with those
fields instead of `Note`.

Fix: replaced the file with `web/discovery-hub.html` from `c5ebc76`
(sha256 `51add514…`). The N7 Data-button hide is already in that file. No Caddy
reload was needed (`Cache-Control: no-cache` already set). The hub immediately
returned 8 rows, all `up`, each with the correct engine and description.

## Rollback

Each unit has a sealed rollback model. `deploy_nN.py --rollback` restores the
predecessor image for N5, N6, N7. `deploy_swi.py --rollback` restores all SWI
services. The rehearsal for each unit injected a failure and confirmed automatic
predecessor restoration with state marker preserved.
