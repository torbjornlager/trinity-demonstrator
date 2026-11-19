# Configurable public admission — 19 November 2026

Qualification began on 19 November; the final live selection and verification completed on 20 November 2026.

**Deployed and verified.** The public N1–N7 preset is now configurable at operator startup. SWI and Trealla select 120 call entries and 120 session creations per 60-second fixed window. ECLiPSe N7 selects 120 shared fresh-engine admissions per client IP per rolling minute. GNU N6 retains its 120-request/minute ingress refill rate and burst of 60, now configurable. These are different accounting units, recorded explicitly in `/node_info.admission`.

N7 retains **four public engines globally and two per client**. Existing native concurrency, actor, CPU, memory, process and execution-time ceilings are preserved. Public access remains OPEN. N0 and the private admin received the same native metadata support while retaining their existing budgets.

## Verification

| Selection | Result |
|---|---|
| Sustained owned fixtures | 140/140 finite HTTP requests each on SWI, Trealla, GNU ingress and ECLiPSe; 560 total |
| Custom low budgets | Native SWI/Trealla two-request refusal and reset; N7 two-start rolling refusal, Retry-After and recovery; GNU two/minute plus burst/refill recovery all pass |
| Real concurrency controls | N7 two/client and four/global; N5 ingress custom one/client and two/global; post-close recovery pass |
| Anonymous visible exercise flows | 34 entries / 136 checks pass in owned fixtures with 120-entry budgets, 16 actor/session slots and three in-flight calls |
| Live critical exercise flows | 30 checks across parallel/fridge on N3/N4 pass |
| Live HTTP prompts | 19/19 each on N2/N3/N4/N5, with four-second session-creation pacing; race submissions unchanged |
| Private image ACTOR gates | 45 release + seven source-directive cases each on SWI and Trealla |
| Integration CI | All 36 local checks pass; GitHub CI passes for the exact source revision |

### Live sustained HTTP measurements

Each node completed 140 finite equality checks, paced 0.6 seconds between request starts. A 61-second quiet period separated this phase from earlier smoke traffic. Native SWI toplevel_call and toplevel_next also consume the HTTP-IP call budget; a 120-entry preset is not a promise that an arbitrary stress pack can run without pacing. Refusals and error bodies are failures, including errors inside HTTP 200. This measures sustained finite HTTP service, not concurrency, arbitrary programs or memory reclamation.

| Node | Result | Observed requests/minute |
|---|---|---|
| N1 | 140/140 | 99.94 |
| N2 | 140/140 | 99.94 |
| N3 | 140/140 | 99.94 |
| N4 | 140/140 | 99.93 |
| N5 | 140/140 | 99.83 |
| N6 | 140/140 | 99.96 |
| N7 | 140/140 | 98.47 |

N7 naming and both N3↔N7 interoperation selections also pass. Its WebSocket checks use 2.1-second spacing; capacity can still refuse admission while engines are being prepared or closed. The owned concurrency control records one such temporary refusal and then verifies the bounds without increasing them.

## Runtime and source identities

| Component | Source | Engine |
|---|---|---|
| Native SWI | `e25b2302017836ff89294999e8fb16f9667cfda6` | SWI-Prolog 11.0.0, unchanged engine files |
| Trealla | `2d5042bb2750b45c640f5bb757567ff50b6f0cb1` | 3.14.20, unchanged engine files |
| ECLiPSe adapter | `31dcdfcdb77f4ea8d8f62aea0a8bb01f3f765c8f` | Existing qualified 7.2.13 engine image unchanged |
| Shared deployment | `21284ba38fa0583686f3eb49eaa79f09d2328bad` | Configuration and metadata changes |
| Browser package | `0d024e5e61b9b87a6abaab60d2b1a6104f4a9215` | SWI 10.1.19; all 12 executable/schema files match the previous package |

The browser execution host has no public HTTP listener or server admission budget. Those settings remain inapplicable locally; remote calls consume the destination server’s budget. GNU’s native engine and query/owner/memory ceilings were not changed. Its existing five-minute idle query retention can still require pauses in bounded-generation selections that discard continuation ownership.

## Rollout and retained findings

Eleven runtime/ingress services were recreated using frozen predecessor and candidate models. The first attempt was rolled back after an exposed-port metadata mismatch. Recovery also identified a stale N7 socket bind path in the canonical model. Original images, port declarations, socket mount and all protected configuration were restored and verified. The retry derives these declarations from actual snapshots and preserves the first attempt’s evidence. A second attempt also rolled back cleanly after an unpaced HTTP prompt stress pack exceeded N2’s 120-query/page request budget. Its original 15 passing and four refused cases remain under attempts/. A third attempt rolled back after the N5 gateway omitted previously enabled retained-HTTP routes. The checked-in route set was restored to match original production, a routing regression check was added, and all 19 prompt cases pass through the corrected owned gateway. Both rendered default ingress configurations match original production byte for byte. A fourth attempt passed all 980 finite requests and all 76 prompt cases, then rolled back because N6 metadata was absent: the presenter overlay had been copied to an inactive path. The final retry copies it to the actual entrypoint and qualifies those active bytes. It retains the completed broad and prompt results for byte-identical images, records their reuse explicitly, and repeats context, critical exercises and all 980 finite requests. The prompt phase uses the previously verified four-second pacing before session creation; reply/abort/halt race submissions and assertions are unchanged.

The final checks preserve access settings, credentials, read-only payloads, mounts, networks, resource bounds and Caddy bytes. Six live servers’ public non-rate setting relations match their before snapshots. The rollback rehearsal injects a failure and restores an owned predecessor while preserving its state marker; it does not use production volumes.

CI initially exposed a test-harness defect: masking ports in raw JSON also replaced numeric admission values. The repair parses JSON first and masks only self_url. All 23 golden/interoperation cases then pass; no language assertion was weakened. An earlier setup attempt also rejected stale browser schema provenance. The corrected pins retain identical executable/schema bytes.

Owned fixture setup corrections included explicit GNU authentication mode, read-only token provisioning, the trusted N7 client-IP header and the direct GNU fixture’s Host translation. Those unsuccessful setup attempts are not runtime-conformance passes.

This is an admission and regression qualification, not a fresh complete language-conformance run. The earlier full report and its failures remain unchanged, including remote context restoration, the public Trealla receive-body cut finding and browser B-SV-006. Raising budgets does not resolve those findings or remove capacity limits.

[GitHub CI](https://github.com/torbjornlager/trinity-demonstrator/actions/runs/44630462680) · [operator controls](../../public-admission.md) · [source and image preservation](execution/preservation.json).

Guarded local recovery: `python3 /Users/lager/trinity-demonstrator/.trinity/admission-120-20261119/release-r5/rollback.py --check` verifies the exact selected services; omit `--check` only for explicit recovery. A newer deployment or changed protected selection makes the guard refuse recovery.
