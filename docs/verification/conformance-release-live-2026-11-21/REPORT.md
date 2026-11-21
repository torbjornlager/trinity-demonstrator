# Conformance fixes release — 21 November 2026

Deployment of the 20–21 November conformance fixes, following
[the release brief](../../RELEASE-BRIEF-2026-11-21.md) and HANDOVER §9–10.
Each unit was captured, built from immutable commits, rehearsed in an isolated
clone with an injected failure, switched after explicit approval and smoke-checked.
Exact identities are in [release.json](release.json).

| Unit | Source | Selected image(s) | Live |
|---|---|---|---|
| N6 | gprolog-port `8eeb3f8` (= `91f21bd` + `94960dd`) | `8caf7235a7f4` | verified 12:25Z |
| N5 | trealla-port `49377b5` (10-file overlay on the exact predecessor) | `d31f2a2a7211` | verified 12:33Z |
| N7 | eclipse-node `a1aef63` runtime (pin `9038bbb`) | adapter `de5c979bab1e`, worker `bcc48cd0fd5e` | verified 12:53Z |
| N0–N4, admin | swi-prolog-node `9239028`, demonstrator `6fc9db8`, browser `4c784f9` | N0 `202f9cbe479b`, N1/N3/N4 `7759b23d172b`, N2 `d3836c21fa46`, admin `26ad505af769` | verified 13:39Z (second attempt) |
| Static assets | browser `4c784f9` | not republished | all eight origins byte-identical |

## Deviations from the brief

- **N6 source.** Live N6 ran gprolog-port `94960dd` (on `portable-core-0.1`,
  computed-call error alignment), not `4059a25`; `91f21bd` lacked it. The
  release uses `8eeb3f8`, a clean cherry-pick of `94960dd` onto `91f21bd`.
- **N6 helpers.** Live N6 ran `n6_contained.py`/`n6_egress.py` from `e00b4f95`
  (localhost `/call` route, validated rpc headers, two-hash leases). The copies on
  `main` expected one-hash leases, which the release GNU controller does not write,
  so egress would have been refused. Demonstrator `6fc9db8` restores them.
- **N7 test.** `9038bbb` narrows a stale extraction-baseline test that `a1aef63`'s
  doubled-quote directive broke; no runtime change.
- **N7 remaining gaps.** PE-008 with `limit=5&timeout=1` still returns a truncated
  page (`success([a],true)`), unchanged from the predecessor; `timeout` alone gives
  `resource_error(time)`. `atom_codes(A,"ab")` raises `type_error(integer,a)` because
  N7 reads `"ab"` as the char list `[a,b]`; `atom_codes/2` on codes works.
- **N1–N4 PE-008** already passed before this release.
- **Static assets.** Every origin (N7 under `/demonstrator/`) already serves
  byte-identical runtime files and the served trees contain no provenance records,
  so republishing would have produced identical trees.

## Qualification

- N6: GNU engine `make check`; 25/25 `local-test` groups (test image with the clang
  ASan runtime; `cc` mapped to clang); `credentials-test` not run (needs the
  comparison checkout layout); 13 demonstrator N6 tests; adapter, helpers, shared
  DB and supervisor byte-identical to the predecessor.
- N5: all 112 Trealla unit groups on the exact image (python3 added only in a test
  image); 150 files verified against `49377b5`; engine 3.14.20 unchanged.
- N7: `check_n7.sh` passes on aarch64 (unit, from-source build, 241 HTTPS
  exact-error cases, real Chrome, conformance, catalog); 247/247 language-contract
  cases and all packaged reports on the exact overlay worker; ECLiPSe binary unchanged.
- SWI: `tools/test.sh` on the release pins; browser manifest `9cf7d60b…`; 45/45 ACTOR
  gate in the exact image; SWI 11.0.0 engine inventory unchanged.

## Live checks

All brief smoke checks pass except the two N7 gaps above. Additional regression
probes (computed-call errors, localhost rpc and N3 rpc on N6; N5→N3, N5→N1 source,
N5→N2→N4 and Linda on N5; five arithmetic/rpc probes on N7; six probes per SWI
node and N4→N3) returned exactly the pre-release answers. Configuration, mounts,
static addresses and unrelated containers were verified unchanged after each switch.

The first SWI attempt rolled back automatically: right after N0–N4 restarted, one
N0 probe got an admission refusal (`inflight_calls` limit 3). All six predecessors
were restored and re-verified; the retry re-probes once after such a refusal and passed.

## Incident: host disk full

During the SWI builds the host volume filled (218 MiB free) and Docker Desktop's
storage became read-only; endpoints kept answering but writable volumes (N5
`/state`) refused writes. After Torbjörn freed space and restarted Docker, N5
admission failed to start because `oauth2_n5` had taken its static address
`172.18.0.2`; it was restored (admission back on `.2`, `oauth2_n5` on `.9`) and
every node re-verified. The cleanup also removed the unused N5/N6/N7 predecessor
images. Recovery images were rebuilt from source and qualified against the
pre-release live answers (N5 and N7 source-exact; N6 `isobase-node` and
`query-supervisor` byte-identical, `query-worker` rebuilt); `--rollback` targets them.
Older releases' recovery commands that reference removed images need the same treatment.

## N5 restart evidence (20 November)

`docker logs` of `3632faaaf5a1` for 13:00–13:45Z were saved privately before the
container was replaced. The only line before the restart is `Killed` at
13:26:43.83Z; `RestartCount` was 1 and Docker did not report an OOM kill.

## Rollback

Private operators are under `.trinity/conformance-release-20261121/`:
`n6/deploy_n6.py --rollback`, `n5/deploy_n5.py --rollback`,
`n7/deploy_n7.py --rollback`, `swi/deploy_swi.py --rollback`. Each is scoped to its unit.
