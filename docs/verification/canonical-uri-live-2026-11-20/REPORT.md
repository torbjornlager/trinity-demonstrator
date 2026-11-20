# Canonical node identity — live verification, 20 November 2026

**Deployed and verified.** Native SWI `254ae3a` runs on N0–N4 and admin; Trealla `d451596` runs on N5. The SWI services use demonstrator `fd7e9f8` and browser package `b5ec41d`. The engines remain SWI-Prolog 11.0.0 and Trealla 3.14.20. N6 and N7 were not upgraded.

Only an empty root path is canonicalized: `https://node/` and `https://node` share actor routing, credentials and owner topology keys. Schemes, authorities, explicit ports, non-root paths, queries and fragments remain distinct. Duplicate canonical credential keys and conflicting endpoint mappings are refused. Explicit node URLs retain receiving transport contexts; ordinary names remain client-context scoped. Trealla caches outgoing connections by client context and canonical node, closes them on retirement, and rejects forged manager control messages. Equivalent URI text works with qualified local control and private toplevel-halt monitors.

## Verification

| Check | Result |
|---|---:|
| Unchanged version 0.2 URI/context case goals against exact SWI/Trealla images | 44/44 |
| Exact-image independent-peer reclamation controls | 2/2 |
| ACTOR release gates against exact images | 45/45 per runtime |
| RPC timeout goals against exact images | 20/20 per runtime |
| All visible OPEN exercises in exact SWI image | 136/136 across 34 entries |
| Local demonstrator integration groups | 36/36 |
| GitHub CI | Both jobs pass |
| Anonymous live URI/context checks, N3/N4/N5 | 63/63; 21 per node |
| Unchanged live RPC timeout goals, N1–N5 | 100/100 |
| Primary public ACTOR selection, N3/N4/N5 | 354/354 |
| Live anonymous parallel/fridge exercise checks | 30/30 |
| HTTP prompt assertions, N2–N5 | 76/76 |
| Sustained finite HTTP probes, N1–N5 | 700/700 |

The live URI selection uses the maintained adapter's assertions and source fixture, with 2.1 seconds between retained-session starts and a 61-second pause between nodes. NU-022 requires equal execution-only credentials and runs only on disposable exact-image fixtures; production peer/operator credentials were not repurposed for client testing. The other 21 cases run anonymously on each live ACTOR node. The separate lifecycle controls observe actual remote actor reclamation through another connection and verify surviving delivery for the other client, closed-context admission and forged-message rejection.

Version 0.1 stays immutable. Ten of its thirteen original case goals, including NU-003/006/011, are byte-identical in version 0.2. NU-001/002/004 now separate canonical address checks from caller-namespace visibility; the dedicated local and explicit-URL context controls retain that coverage. The [goal comparison](execution/uri-goal-comparison.json) makes this distinction explicit. Old mixed assertions are superseded according to the documented receiving-context contract, rather than represented as passing unchanged. The current inventory links original observations to these specific proofs; repeated observations are not independent bugs.

## Setup history and scope

Initial package/build setup stopped before tests because browser schema provenance still named the previous native revision. The browser's schema provenance was updated and all twelve executable/schema/engine-metadata payloads remain byte-identical. Initial cross-image URI checks recorded 12 pass and 32 sandbox refusals because temporary Docker hostnames lacked fixture allowlist entries. Adding only the two disposable logical node origins made all 44 unchanged assertions pass. These setup refusals are retained under diagnostics and are not classified as production regressions. No assertion or watchdog was relaxed.

This is a focused release, not a new full sweep. Other-runtime URI adoption, N6/N7 fixture issues and the remaining work queues retain their separate findings. The earlier native qualification and historical sweep remain unchanged.

## Preservation and recovery

Every engine/library file in each of the five distinct candidate images matches its live predecessor. Seven runtime services were recreated from frozen service models. Access modes remain OPEN where previously OPEN. Public rate settings, concurrency/resource limits, credentials, mounts, network aliases and read-only payloads were preserved. Caddy and unrelated Compose service identities are unchanged. N5 retains its existing application/launch layout with an audited overlay of every Trealla file changed since the deployed predecessor.

The isolated rollback rehearsal injected a health failure, restored the predecessor and preserved a volume marker. Private recovery inputs are under `.trinity/canonical-uri-release-20261120/release/`. The guard checks exact selected IDs, image IDs, sealed inputs and host-selection hashes:

`python3 .trinity/canonical-uri-release-20261120/release/rollback.py --check`

Omitting `--check` restores this release's predecessors; a newer deployment makes the guard refuse recovery. No production rollback was needed. [Summary](SUMMARY.json), [CI](https://github.com/torbjornlager/trinity-demonstrator/actions/runs/44728428742) and [artifact hashes](files-sha256.json).
