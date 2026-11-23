# N6 peers release — live verification, 23 November 2026

**Deployed and verified.** N6's outbound allowlist now includes N0 and N7
in addition to N1–N5. `rpc/3` from N6 to any other node of the demonstrator
domain succeeds; `src_uri` queries against N7 work for the first time.

## What changed

Branch `n6-peers` (`8c901b3`): `APPROVED_PEER_HOSTS` added to `n6_egress.py`
as a single source of truth for N6's permitted outbound peer hosts —
`n0`–`n5`, `n7` (all nodes except N6 itself, which is reached via
`rpc(localhost, ...)`). `n6_adapter.py` and `n6_contained.py` updated
consistently.

| File | Change |
|------|--------|
| `Deployment/n6_egress.py` | Added `APPROVED_PEER_HOSTS = tuple(f'n{n}.elfenbenstornet.se' for n in (0,1,2,3,4,5,7))` |
| `Deployment/n6_adapter.py` | Aligned with egress policy |
| `Deployment/n6_contained.py` | Aligned with egress policy |

## Image

| | SHA |
|---|---|
| Rollback (22 Nov candidate) | `sha256:b86ec3b3aa9e` |
| Candidate (this release) | `sha256:dcaa3fe4fb22` |

Built as an overlay on `n6-discovery-candidate:c5ebc76` using
`.trinity/n6-peers-20261123/build/Dockerfile`. The `old.sha256` guard
verified the three files in the base image before replacement.

## Rehearsal

Rehearsal (`n6-rehearsal-20261123`) passed:

- Predecessor healthy (old image confirmed)
- Candidate healthy; discovery fields verified (GNU Prolog 1.6.0)
- All probes passed (generic, n6, n6-regression sets; no new FAILs, no regression changes)
- Injected failure: predecessor restored, state confirmed
- Production containers untouched throughout

## Live switch

Operator: `.trinity/n6-peers-20261123/deploy_n6.py --execute-live`

| Stage | Result |
|-------|--------|
| Preflight (rehearsal_pass confirmed) | ✓ |
| Container switched to `dcaa3fe4`, healthy | ✓ |
| `/node_info`: GNU Prolog 1.6.0, description present | ✓ |
| Probes (generic, n6, n6-regression live) | ✓ |
| Preservation (config unchanged, unrelated containers untouched) | ✓ |

## Post-switch checks

| Check | Result |
|-------|--------|
| `/node_info` returns GNU Prolog 1.6.0, description | ✓ |
| `rpc('https://n7.elfenbenstornet.se', ancestor_descendant(X,Y), [src_uri('https://n2.elfenbenstornet.se')])` → 6 answers | ✓ |
| `rpc('https://n1.elfenbenstornet.se', member(X,[a,b,c]))` | ✓ |
| `rpc('https://n2.elfenbenstornet.se', mortal(socrates))` | ✓ |
| `rpc('https://n3.elfenbenstornet.se', X=hello)` | ✓ |
| `rpc('https://n4.elfenbenstornet.se', X=hello)` | ✓ |
| `rpc('https://n5.elfenbenstornet.se', X=hello)` | ✓ |
| `src_uri` → N1 (N1 rejects `use_module` directive; N6 reached N1, no outbound denial) | ✓ |
| `src_uri` → N2: `mortal/1` returns [socrates,plato,aristotle] | ✓ |

## Rollback

`.trinity/n6-peers-20261123/deploy_n6.py --rollback` restores `b86ec3b3`
(22 November N6 candidate).
