# Release brief, 21 November 2026: conformance fixes to all nodes

This brief is for a Claude Code session on Torbjörn's Mac, where the nodes run.
It covers deploying the 20–21 November conformance fixes, running the full live
conformance sweep and updating the report. The procedure in `HANDOVER.md`
§9–10 governs everything below. Where this brief is shorter, follow the
handover.

**Torbjörn asked for this release on 21 November 2026.** Each live switch is
still a separate step: tell him before each one and stop if a check fails.

## 1. Sources

All of these are on GitHub. Five `main` branches were fast-forwarded on
21 November, so main and the pinned commit are the same.

| Repository | Commit | Where | Node(s) |
|---|---|---|---|
| swi-prolog-node | `9239028` | main | N0–N4, admin |
| swi-wasm-node | `4c784f9` | branch `claude/conformance-20261120` | browser runtime, every origin |
| trealla-port | `49377b5` | main | N5 |
| gprolog-port | `91f21bd` | main | N6 |
| eclipse-node | `a1aef63` | main | N7 |
| trinity-conformance | `a7a4a7b` | main | the suite |
| trinity-demonstrator | `edf4e71` (pins; this brief is the next commit) | branch `claude/conformance-20261120` | pins for all of the above |

**Before you build:** ask Torbjörn whether to fast-forward `main` of
swi-wasm-node and trinity-demonstrator to these branch tips. Both are
fast-forwards. The cloud session could not push them to main without his
explicit go-ahead. Build from the exact commits either way.

What changed is in the project doc `claude/STATUS-2026-11-20.md` and in each
commit message. In short:

- **SWI:** rpc and promise now call the path below the node URI; `http_timeout/1`
  bounds the whole request. main also gains the
  `codex/welcome-release-20261113` commits that live N1–N4 already run.
- **Browser package:** only the schema provenance changes (native `9239028`).
  The schema bytes are unchanged. The package tests and the statechart
  equivalence check pass. The manifest digest is `9cf7d60b…`.
- **Trealla:** receive-body cut (SR-015); rpc `timeout`/`http_timeout`
  semantics; `rpc(localhost,…)` goes to the local listener (Torbjörn's
  decision); `/call` honours the `timeout` parameter. All 112 unit groups pass.
- **GNU:** text URIs; errors after answers on unbounded pages; `succ/2`;
  `sleep/1` admitted in ISOBASE. main also gains the
  `codex/current-manual-comparisons` commits that live N6 already runs.
- **ECLiPSe:** ISO doubled quotes accepted in every reading module;
  `atom_codes/2`, `atom_concat/3`; `halt` and missing-module goals refused;
  errors reported for omitted limits; page cap 100. **Most of these changes are
  in `.ecl` worker sources.** The worker image must be rebuilt, not only the
  `wp_n7` adapter.

## 2. Release units (HANDOVER §9.1)

| Unit | Rebuild | Notes |
|---|---|---|
| N6 | GNU image from `91f21bd` | Link `-lm` (already in the source). The live N6 behaves like `4059a25`, but the old pin said `1f20772`. Capture which compose model is actually live before replacing it. |
| N5 | Trealla overlay on the exact predecessor image, as in the last N5 release | Then refresh the admission workers. **First** save `docker logs` of the N5 container for 20 Nov 13:20–13:27 UTC (it was `3632faaaf5a1`). It restarted on its own during the 20 Nov sweep, and replacing the container loses that evidence. |
| N7 | Worker image (`Deployment/Dockerfile.eclipse-n7`, aarch64) **and** the `wp_n7` adapter | Run `check_n7.sh` against the candidate first. The ARM64 build was never run in the cloud; the fixes were only tested on x86_64 ECLiPSe 7.2_13. Keep the qualified engine and shell assets. |
| N0–N4, admin | SWI images from `9239028` plus browser package `4c784f9` | Assemble the browser payloads with `tools/setup_swi.py`, then run `tools/test.sh`. |
| Static assets | Browser package on every catalog | The files are the same apart from the provenance records. Republish so every origin matches the pin. |

Suggested order, one unit at a time, with a live check between units: N6, N5,
N7, SWI, then static assets.

## 3. For each unit

1. **Capture the predecessor** in a new private directory (§9.2): image IDs,
   compose model, environment hashes, mounts and Caddy pointers. Never put
   secrets in Git or chat.
2. **Build from the immutable commits** above. Use BuildKit secrets for
   private repositories. Don't use broad `docker compose up --build`,
   `down -v`, prune, `reset --hard` or force pushes (§10.4, §9.1).
3. **Rehearse** in a clone of the deployment model with isolated writable
   volumes (§9.4). Show that a failed health check restores the predecessor.
4. **Switch,** then run the smoke checks below. If one fails, capture logs and
   state first, then roll back. Don't patch the live system.
5. **Record** the image IDs and results in a deployment record under
   `docs/verification/`.

## 4. Smoke checks after each switch

Send each goal to `/call` with `format=prolog`, the goal URL-encoded, and
`template` given where shown.

| Node | Goal | Expect |
|---|---|---|
| all | `(X=a;sleep(1.5),X=b)`, template `X`, `limit=5&timeout=1` | `error(error(resource_error(time),_))`, not `success([a,b],false)` |
| N3/N4 | `rpc('https://n3.elfenbenstornet.se', X=1)`, template `X`, sent to N4 | `success([1],false)`: rpc between nodes still works. The path fix only shows for nodes served below a path. |
| N5 | `/call` with `timeout=abc`, sent with owner credentials | `type_error(number,abc)` |
| N5 | `rpc(localhost, X=1)` | succeeds through the local listener |
| N6 | `(sleep(0.05),X=a)`, template `X` | `success([a],false)` |
| N6 | `catch(succ(1,1.5),E,true)`, template `E` | `type_error(integer,1.5)` |
| N6 | `catch(rpc(42,true),E,true)`, template `E` | `type_error(atom_or_string,42)` |
| N7 | `X='it''s'`, template `X` | success, with the atom `it's`. Before the fix: "Invalid request or goal". |
| N7 | `atom_codes(A,"ab")`, template `A` | `success([ab],false)` |
| N7 | `catch(halt,E,true)`, template `E` | `permission_error(call,sandboxed,halt)` |

## 5. Full conformance sweep

1. Use trinity-conformance `a7a4a7b` (main). Create
   `reports/2026-11-21-post-release-conformance/`.
2. Reuse the orchestration of `reports/2026-11-20-post-uri-full-conformance/`:
   `orchestration/run_public.py`, `run_more.py`, `run_libraries.py`,
   `native.py`, then `build_report.py`, `render_report.py`,
   `validate_report.py` and `verify_completion.py`. Copy them into the new
   report's `orchestration/`. Change only paths, dates and pins, and record
   every other change.
3. Keep the same admission budgets and session intervals as 20 November, so
   N6's capacity refusals stay comparable.
4. The report must compare against 20 November, pack by pack and node by node.
   Use the classification in `claude/STATUS-2026-11-20.md`: N6 capacity
   refusals, out-of-scope rows, superseded 0.1 assertions, sandbox-only rows on
   N7, harness bugs, real defects.

These should no longer fail:

- PE-008 everywhere
- SR-015 on N5
- PE-014..018 on N6 and N7
- SU-HTTP-016 on N6 and N7
- URI-001..006 and URI-010 on N6
- TXT-019/023/024/026
- OPT-004, URI-007 and URI-011 on SWI and Trealla
- HTTP-FIELD-024..026 and 051..053 on N5
- most N7 "Invalid request or goal" rows
- CA-002, CA-013/014 and LC-082/083/087/088 on N7

These are expected to remain:

- N7 NU-020/021: one peer connection per spawn, a design gap
- ER-007 and the HTTP-CTL NUL cases on N6: classification and representation
- SL-014..017 on sandbox-off N7: they should be marked not applicable
- live LOCAL-006/007, which need a peer that serves `local_node_loaded/1`

5. Push the report to trinity-conformance main **if Torbjörn agrees**,
   otherwise to a branch.

## 6. After the release

- Update the live selection at the top of `HANDOVER.md`: N0–N4 `9239028`,
  browser `4c784f9`, N5 `49377b5`, N6 `91f21bd`, N7 `a1aef63`.
- Update the project doc `claude/STATUS-2026-11-20.md`, or write a dated
  successor, with what was deployed and what the sweep found.
