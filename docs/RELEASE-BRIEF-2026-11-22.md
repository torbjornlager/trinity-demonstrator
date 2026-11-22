# Release brief, 22 November 2026: self-describing nodes and the Discovery Hub

This brief is for a Claude Code session on Torbjörn's Mac, where the nodes run.
It covers the Discovery Hub change: every card now shows only what the node
reports about itself in `/node_info`. The procedure in `HANDOVER.md` §9–10
governs everything below. Where this brief is shorter, follow the handover.

**Torbjörn asked for the commits and this brief on 22 November 2026, had the
branches pushed the same evening, ran every test suite in §3 on his Mac, and
asked for the release.** Each live switch is still a separate step: tell him
before each one and stop if a check fails. Fast-forwarding `main` is a separate
decision afterwards (§6).

## 1. Sources

All commits are on GitHub, on branches named `discovery-self-description`.

| Repository | Commit | Parent | Node(s) |
|---|---|---|---|
| swi-prolog-node | `67f0b17` | `9239028` (main, live N0–N4) | N0–N4 |
| swi-wasm-node | `1d6ee0d` | `4c784f9` (main, live browser package) | browser runtime, every origin |
| trealla-port | `edf2283` | `d451596` (live N5) | N5 |
| eclipse-node | `cbe235c` | `9038bbb` (main; live N7 is `a1aef63`, and `9038bbb` only changes a test) | N7 adapter |
| trinity-demonstrator | `ddafeaf` (test fix), `bfb6724` (browser pin), `77e15d5` (SWI and Trealla pins), `e7f1862` (hub); this brief is the next commit | `bcdc171` (main) | N0–N6, hub page |

The trealla-port branch deliberately starts at `d451596`, not `main`: `main`
still has the `7a8e8ce` receive-guard regression that caused the 21 November N5
rollback (STATUS-2026-11-21, open work item 1).

swi-wasm-node `1d6ee0d` only records native `67f0b17` as its schema source; the
schema bytes are unchanged. The browser package manifest digest becomes
`e874d2de…`. Packaging is reproducible: rebuilding `4c784f9` against `9239028`
gives the previous pin's `9cf7d60b…`.

The demonstrator commits after the live runtime `6fc9db8` are already deployed
(HANDOVER, top): `75ae2fa` (N5 admission at `172.18.0.12`, step 1 of
`docs/WP_NET_ADDRESS_PLAN.md`) and `bcdc171` (N6 `src_uri` fix, live as overlay
image `6330bcda1582`). Nothing in this release changes them.

## 2. What changed

- **SWI (`swi-prolog-node`):** `/node_info` reports `implementation`
  (`"SWI-Prolog"`), `version` and, when the owner sets the new `description/1`
  node option, `description` (one line, at most 160 characters). A RELATION
  node advertises exactly its relation patterns as `provides`, so N0 no longer
  lists `member/2` or its helper predicates. Recorded in DEVIATIONS.md.
- **Browser package (`swi-wasm-node`):** schema provenance only.
- **Trealla (`trealla-port`):** the same fields and option. The launcher reads
  `WP_DESCRIPTION`.
- **ECLiPSe (`eclipse-node`):** the adapter reports `"ECLiPSe Prolog"` (was
  `"ECLiPSe CLP"`), the shared database's 22 exported predicates as
  `provides` (was `[]`), and `self_contained: true`. In public mode it adds a
  description, which `N7_DESCRIPTION` overrides. Adapter only, no worker
  change.
- **Demonstrator:** the hub seed holds only addresses, and the hub harvests
  engine, version and description from each node. `node_directory_row/9`
  becomes `/10`. N6's adapter reports its own fields. N1–N4 set their
  descriptions in `start_n1.pl`…`start_n4.pl`; N0 and N5 get `WP_DESCRIPTION`
  in their compose files. See `docs/DISCOVERY_NODE_METADATA.md` and
  DEVIATIONS.md.

## 3. Tests (all passed on the Mac, 22 November)

SWI runs used `/usr/local/bin/swipl` (SWI-Prolog 11.0.0, the version the live
N0–N4 images use).

| Repository | Command | Result |
|---|---|---|
| swi-prolog-node | `SWIPL=/usr/local/bin/swipl ./tools/test.sh` | every tier passed; T4_NATIVE 1104/1104; T5 `node_info_agrees` |
| trinity-demonstrator | `tools/setup_swi.py --native-root …/swi-prolog-node --browser-root …/swi-wasm-node`, then `./tools/test.sh DISCOVERY DEMONSTRATOR` | DEMONSTRATOR 5/5; DISCOVERY 7/7 and 42/42; browser card check |
| trealla-port | `./tools/test.sh unit` (cloud, pinned 3.14.20) and `./tools/test.sh interop` (Mac, `TPL=…/trinity-demonstrator/.trinity/trealla-engine/tpl`) | all passed |
| eclipse-node | `tools/bootstrap_n7.sh --seed-local` (runs `check_n7.sh`) | 77 unit tests; language contract 247/247; HTTPS metadata, shell and Chrome checks; local conformance; catalog. `actor-core` reports 7 unsupported because that local run does not advertise ACTOR. |

**Known intermittent crash:** `discovery_integration:live_peer_probed_up` can
crash SWI-Prolog (signal 11 in an `httpd@3970` worker) while probing the fixture
peer. It happened once on 22 November and twice on 20 November, before these
changes (`Deployment/verification/discovery-labels-20261120/`). The rerun
passed. The cause is still unknown.

An older node accepts `description(...)` and ignores it, so the order of the
units below only decides when descriptions appear, not whether anything breaks.

## 4. Release units

Suggested order, one unit at a time, with the checks in §5 between units:

| Unit | Rebuild | Notes |
|---|---|---|
| N5 | Trealla overlay from `edf2283`, as in the last N5 release | Admission workers stay as they are (address `.12`). Set `WP_DESCRIPTION` as in `compose.trealla-n5.yaml`. |
| N7 | `wp_n7` adapter from `cbe235c` | No worker image rebuild. Keep the qualified engine, shell assets and the rotated N7→N3 peer bearer. |
| N6 | adapter image from the demonstrator branch | `n6_adapter.py` only; keep the `n6_egress.py` fix (`bcdc171`) that is already live. |
| N1–N4, admin | SWI images from `67f0b17` plus browser package `1d6ee0d` | `tools/setup_swi.py`, then `tools/test.sh`. **This is the next SWI recreate, so carry the HANDOVER items:** step 2 of `docs/WP_NET_ADDRESS_PLAN.md` (pin the six SWI addresses) and `pids_limit` in the Compose models (N3/N4 1024; N0, N1, N2 and admin 512). |
| Static assets | browser package `1d6ee0d` on every catalog | Provenance records only; republish so every origin matches the pin. |
| N0 | hub image from the demonstrator branch, last | Same `pids_limit` (512) and address-plan items. It needs the nodes to report the fields; otherwise its cards show no engine. |

For each unit, follow §3 of the 21 November brief: capture the predecessor,
build from the exact commits, rehearse, switch, check, record.

## 5. Checks after each switch

`curl https://nN.elfenbenstornet.se/node_info` for the node just switched:

| Node | Expect |
|---|---|
| N0 | `implementation` `"SWI-Prolog"`, a `version`, `description` starting "Discovery hub."; `provides` is exactly the 13 `node_*` relations (no `member/2`) |
| N1–N4 | `"SWI-Prolog"`, a version, and the description from its start script |
| N5 | `"Trealla Prolog"`, `"3.14.20"`, "Trealla Prolog implementation of the ACTOR profile." |
| N6 | `"GNU Prolog"`, the engine version, "GNU Prolog port of the ISOBASE profile." |
| N7 | `"ECLiPSe Prolog"`, `"7.2.13"`, 22 `provides` including `human/1`, `self_contained: true` |

Also rerun each node's existing smoke checks from its last release record (for
N6, the two `src_uri` goals), since the image changes.

After N0: open `https://n0.elfenbenstornet.se/discovery-hub` and check that every
card shows the node's own engine and description, a routes line, no
"owner-only" text, and no "registry" badge.

## 6. After the release

- Ask Torbjörn whether to fast-forward each repo's `main` to its
  `discovery-self-description` branch. For trealla-port this is not a
  fast-forward (the branch starts at `d451596`): merge or rebase it onto `main`
  once the `7a8e8ce` regression is fixed.
- Update the live selection in `HANDOVER.md` (including that the address plan's
  step 2 and `pids_limit` are now in the Compose models) and write a dated
  status note.
