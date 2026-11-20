# Discovery Hub implementation labels — 20 November 2026

The live Discovery Hub again labels every node with its Prolog implementation.
Source commit `825b18152abd4312ae8719fe646db8abbfcfdbbf` is deployed on N0, with matching registry,
seed and page code. The original feature (`79d287b4`) remained on a development
branch and was absent from main; the live page still requested the relation,
but the running registry returned `Unknown procedure: node_implementation/2`.

| Nodes | Implementation |
|---|---|
| N0–N4 | SWI-Prolog |
| N5 | Trealla Prolog |
| N6 | GNU Prolog |
| N7 | ECLiPSe CLP |

Labels come from curated `seed_implementation/2` metadata and remain available
when a peer cannot be probed. `node_implementation/2` is published through the
RELATION API. The page batches its queries within the three-request concurrency
bound and warns if optional node details cannot be fetched.

The [CI run](https://github.com/torbjornlager/trinity-demonstrator/actions/runs/44749959148) passed both native/demonstrator and WASM jobs.
The DISCOVERY tier now includes the registry integration suite as well as the
scheduling and browser-query checks. All 45 Prolog discovery checks passed
locally and in the exact deployed image. Browser checks cover all eight label
values, unavailable peers, escaping, missing-metadata warnings and query
concurrency. Google Chrome also loaded the actual [live hub](https://n0.elfenbenstornet.se/discovery-hub)
and verified eight visible labels with no page or query errors.

Only N0 was recreated. Its access profile remains RELATION/OPEN; arbitrary
`true/0` queries remain refused. The existing native/browser dependency
selections, environment, mounts, resource limits, aliases and other service
container/image identities were preserved. Deployment verification completed
at `2026-11-20T14:17:56Z`. The previous image and Compose model are retained
privately for rollback. Before the final deployment, the unused candidate image
was removed while CI ran, so that start attempt was refused before N0 changed.
The image was rebuilt from the same source and all 45 tests plus browser checks
were repeated. A later attempt rolled N0 back because the preservation check
compared environment-list order. The values were identical; the check now
compares names and values. Final deployment and verification passed.

During qualification, a temporary RELATION variant of the existing multi-node
integration fixture crashed twice in SWI-Prolog (exit 139) while probing a peer.
The final source restores that fixture's original ACTOR profile and retains
all implementation assertions. The final fixture passes; a separate running
RELATION hub passes the real browser check. The native crash cause remains
undetermined; this release does not claim to repair it. Both failed outputs
and the predecessor/control results are retained below.

[Deployment evidence](verification/discovery-labels-20261120/verification.json) ·
[Image qualification](verification/discovery-labels-20261120/qualification.json) ·
[CI evidence](verification/discovery-labels-20261120/ci.json) ·
[Live browser assertions](verification/discovery-labels-20261120/live-browser.json) ·
[Live screenshot](verification/discovery-labels-20261120/live-browser.png) ·
[Fixture crash](verification/discovery-labels-20261120/image-discovery-tests-crash.txt) ·
[Second fixture crash](verification/discovery-labels-20261120/candidate-standalone-tests.txt) ·
[Artifact hashes](verification/discovery-labels-20261120/files-sha256.json).
