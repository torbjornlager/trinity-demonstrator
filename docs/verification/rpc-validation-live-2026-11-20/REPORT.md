# RPC timeout validation — live verification, 20 November 2026

**Deployed and verified.** SWI native `0bf7286` runs on N0–N4 and admin; Trealla `e99126b` runs on N5. The SWI services use demonstrator source `ed70764` and browser package `ca8e689`. SWI-Prolog remains 11.0.0 and Trealla remains 3.14.20. Every engine/library file matches the selected predecessor. N6 and N7 were not upgraded.

Explicit RPC/promise execution timeouts must be numbers. SWI now rejects unbound/none values before dispatch; Trealla rejects infinite. Omitted defaults and the independent yield/HTTP timeout behavior are preserved. The repaired case IDs are RPC-TIME-001/002/010/011 for SWI and RPC-TIME-003/012 for Trealla.

## Fresh verification

- All **100/100 unchanged RPC timeout assertions pass**: 20 each on N1–N5. N3/N4/N5 use the original retained WebSocket query runner, including finite-answer and halt checks; N1/N2 use finite HTTP with the same assertion goals. HTTP starts are spaced by at least 0.85 seconds; retained session starts by at least 2.1 seconds. The manifests and goal bodies are unchanged.
- Each exact candidate runtime image passes **20/20 RPC timeout goals** and the **45/45 ACTOR release gate**, including ownership and lifecycle assertions. These are disposable private fixtures, not owner-level tests against production.
- All **36 local consumer integration groups** and both [GitHub CI jobs](https://github.com/torbjornlager/trinity-demonstrator/actions/runs/44707458834) pass for the pinned source. The previously qualified Trealla source matches the committed source in every recorded file: 111 unit groups passed on each of macOS and Linux. The five cache properties retain separate 30-second watchdogs; the aggregate 150-second budget is documented in the immutable cleanup qualification.
- The primary public ACTOR selection passes **118/118 on each of N3/N4/N5**: 354 cases. Additional checks cover HTTP profiles, client naming, source transfer, discovery, Linda and cross-runtime RPC.
- All **30 anonymous parallel/fridge exercise checks**, **76 HTTP prompt cases** across N2–N5 and **700 finite sustained HTTP probes** across N1–N5 pass. A 61-second quiet period separates the main phases. Prompt session creation is spaced by four seconds; the reply/abort race assertions are unchanged.
- Fresh HTTP requests remain isolated; explicit anonymous retained sessions preserve shared ownership. Public access remains OPEN. The admission budget stays at 120 starts per minute; concurrency/resource limits, credentials, mounts, networks and read-only payloads are preserved. Caddy and unrelated persistent service identities are unchanged.

This is a focused follow-up. It does not replace the complete sweep or certify the remaining findings. The [current issue inventory](https://github.com/torbjornlager/trinity-conformance/blob/main/CURRENT_ISSUES.md) links each original observation to reviewed repair evidence; repeated observations are not independent defects. URI routing/source transfer is the next work queue.

## Qualification setup observations

Two initial fixture setup attempts are retained separately. Trealla's production image lacks Python, so the in-container controller could not run; the established host controller then passed the gate through a disposable loopback-only fixture. A direct Prolog loader initially did not import rpc/3 and produced existence errors; loading the committed RPC test fixture imports the API and all 20 unchanged assertions pass. Neither setup error is counted as a runtime semantic failure or a passing test.

The URI-text documentation sync follows the author-directed 17 November contract. No URI/monitor runtime behavior changed. The browser pin changes provenance only: all 12 executable/schema/engine-metadata files match the previous package byte for byte.

## Preservation and recovery

Seven runtime services were recreated from frozen predecessor models. N5 uses a minimal overlay of every changed Trealla source file since its predecessor, plus the corrected shared HTML manual; its existing mixed application/launch layout is retained. All 147 tracked root Prolog files also match the committed Trealla source in a read-only live audit. The full Trealla checkout is not represented as a clean demonstrator checkout. SWI application and native checkout revisions, and N5's deployed overlay bytes, were verified after deployment.

The isolated rollback rehearsal injected a candidate health failure, restored the predecessor and preserved a volume marker. Recovery inputs remain private under `.trinity/rpc-validation-release-20261120/release/`. The guard verifies exact selected container IDs, image IDs, sealed inputs and host selection hashes:

`python3 .trinity/rpc-validation-release-20261120/release/rollback.py --check`

Omitting `--check` performs recovery of this exact release. A later deployment makes the guard refuse recovery. Canonical selection and both SWI/N5 pointers identify the new models. No production rollback was required.

[Summary and image identities](SUMMARY.json) · [artifact hashes](files-sha256.json).

The auxiliary runner check initially used an obsolete default Node and failed three WASM-adapter tests before execution. With the qualified Node 22.23.4, all 123 runner tests pass without source or assertion changes. Both logs are retained.
