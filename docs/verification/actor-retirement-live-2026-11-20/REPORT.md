# Actor retirement repair — live verification, 20 November 2026

**Deployed and verified.** Native SWI `0c11f2c` is selected on N0–N4 and the private admin node. The demonstrator runtime source is `8318918`, with browser package `b2fd3fe`. SWI-Prolog remains 11.0.0; all engine files match each predecessor. The browser revision updates schema provenance only: all 12 executable/schema/engine-metadata files remain identical.

The repair removes a terminated actor's PID mappings before delivering its monitor notification. The previous [triage report](https://github.com/torbjornlager/trinity-conformance/blob/main/reports/2026-11-20-regression-triage/REPORT.md) reproduced the race in both old and current revisions and verified 1,000 successful NU-003 repetitions in the repaired candidate.

## Qualification and live checks

- The deterministic retirement-order test passes in all four exact candidate images. The disposable image ACTOR release gate passes all 45 cases, including ownership and lifecycle cases.
- Native and demonstrator integration checks, browser equivalence and WASM checks are recorded under execution/. The exact deployed source passed both [GitHub CI jobs](https://github.com/torbjornlager/trinity-demonstrator/actions/runs/44690145032).
- Public N3 and N4 each pass the unchanged NU-003 assertion 100 times in fresh sessions, with 2.1-second start pacing: **200/200 pass**.
- The complete primary public selection passes **118/118 cases on each of N3 and N4**, with 2.1-second session pacing. Additional live smoke checks pass actor, naming, monitor, source/URI, Linda, discovery, N3→N4 interoperability and N5/N7 consumer checks through the SWI nodes. ISOBASE HTTP checks pass on N1/N2.
- All **30 anonymous parallel/fridge exercise checks** pass on N3/N4. Fresh HTTP isolation and explicit anonymous retained-session sharing also pass.
- All **57 HTTP prompt cases** pass across N2/N3/N4. Session creation is paced at four seconds; prompt reply/abort races and assertions are unchanged.
- All **560 finite sustained HTTP probes** pass across N1–N4, with 0.6 seconds between starts. A 61-second quiet period separates the broad, prompt, NU-003 and sustained phases.

This is focused deployment verification, not another complete conformance sweep. The prior full sweep remains immutable. N6's 56 passing paused replays remain in the triage report; this deployment does not rerun or change N6. Existing context, Trealla and browser findings remain open. The earlier transient N6 localhost transport error still has no proven cause.

## Initial local WASM failure

The first local integration run passed 35 groups and failed one browser worker interruption-cleanup scenario in WASM. Its initial result and logs are retained. All four focused old/current package replays pass in about 34 seconds each. The subsequent complete WASM recheck passes with its original assertions and deadlines. The focused diagnostic controller has a 90-second watchdog; the complete suite retains its 60-second scenario watchdog. The browser runtime bytes are unchanged, and this follow-up does not establish the precise cause of the initial transient failure.

## Preservation and recovery

Six SWI services were recreated. Their access mode, credentials, complete environment, command/entrypoint, ports, networks, mounts, read-only payloads and resource bounds are preserved. Caddy bytes and unrelated persistent Compose container/image identities are unchanged. Public non-rate settings match their before snapshots. No admission limits are raised.

The predecessor/candidate models and operator inputs are frozen privately under `.trinity/retirement-release-20261120/release/`. An isolated injected-failure rehearsal restores a predecessor and preserves a state marker. The live recovery guard verifies exact selected container identities and host-selection hashes:

`python3 .trinity/retirement-release-20261120/release/rollback.py --check`

Omit `--check` only when explicitly recovering this release. A changed deployment makes the guard refuse recovery. Current canonical selection and the SWI pointer identify these new models; the N5 pointer is unchanged. No production recovery was needed during this cutover.

[Summary and image identities](SUMMARY.json) · [artifact hashes](files-sha256.json).
