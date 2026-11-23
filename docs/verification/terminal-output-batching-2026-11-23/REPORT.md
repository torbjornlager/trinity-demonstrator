# Terminal output batching — live verification, 23 November 2026

**Deployed and verified.** N0–N6 now serve the batched/streamed terminal page
from the new Caddy static root `termout-20261123`. UI-only release: no
container was recreated, and N7 was not touched.

## Source

`web/demonstrator.html` from `main` = `0886105` (`95511b1` change + release
brief), fast-forwarded from `00ad413`. Page sha256
`10678726f92da892964a7346592c794f2292e9d9b22288ed95919cc9dae6610a`.
See [the release brief](../../RELEASE-BRIEF-2026-11-23.md) for the change.

## Pre-release qualification

**Shared tests.** `SWIPL=/usr/local/bin/swipl` (SWI-Prolog 11.0.0), Node
22.23.4: `./tools/test.sh` exit 0. All 16 tiers passed (TEXT, T0–T5,
SERVICE_TEXT, DEMONSTRATOR, DISCOVERY, LINDA, MODEL, MODEL_SXML, JEV, LINT,
WASM). The WASM tier includes `swi_wasm_rpc_bridge smoke: PASS`.

**Browser test with the candidate injected into live pages**
(`CANDIDATE_HTML=web/demonstrator.html TERMINAL_NODES=3,4,5`,
[`terminal-output-candidate.json`](terminal-output-candidate.json)):

| Node | 7 stream cases | 5,000-line burst, max round trip | Abort under flood: max round trip / abort frame seen |
|---|---|---|---|
| N3 | pass | 46 ms | 27 ms / 74 ms |
| N4 | pass | 93 ms | 73 ms / 155 ms |
| N5 | pass | 8 ms | 15 ms / 73 ms |

**Spot checks with the candidate injected** (control: same checks on the live
`00ad413` page):

| Target | Observation |
|---|---|
| N2, ISOTOPE | Node sends `stdout`. Candidate: `ab`, `a\n\nb\nc`, all correct. Live page showed `nl,nl` as four blank lines. Burst throughput is transport-bound (one HTTP poll per output message): 300 lines 4.7 s candidate vs 7.1 s live. |
| N6 | Only ISOBASE (`stateless`) is allowed, so no `output` messages exist. `write/1` is refused by the profile on both pages, and `X is 6*7` works. The per-node `WEB_PROLOG_HOST` (6 remote nodes, N0 hub URL) is preserved. |
| N7 | Live page only. N7 **does** send `stdout`, and its own shell already streams and batches output: all cases correct. Its logger is unbounded (4,021 entries after 2,000 lines). |
| SWI-WASM | Output identical to the live page, including a pre-existing single-space line for each blank line from `nl,nl`. |

Logger after a 2,000-line burst with the candidate: 1,000 entries (cap held).

## Live switch

The edge was left in place and repointed. Caddy container `56591dbdf62b`
(image `95a6701892f9`, v2.11.7) was reloaded gracefully and kept the same
identity.

1. **Predecessor re-verified.** Caddyfile sha256 `dd2bdf66…af5e5`. Live root
   `uri-20261117`: N0–N5 `demonstrator.html` `eefa992d…` (byte-identical to
   `00ad413`), N6 `1306b736…` (`00ad413` plus one `WEB_PROLOG_HOST` line).
2. **New root.** `cp -a /srv/trinity/uri-20261117 /srv/trinity/termout-20261123`.
   Only `nX/demonstrator.html` was replaced: N0–N5 with the candidate, N6 with
   the candidate plus the same host-config line (sha256 `cbbe0eef…bceee`).
   Owner `502:20`, mode `600` / `700`, as in the predecessor.
3. **New root checked.** 524 files in each root and identical file sets.
   Exactly 7 hashes differ, all of them `*/demonstrator.html`.
4. **Caddyfile.** Exactly 8 `root` lines changed from `uri-20261117/nX` to
   `termout-20261123/nX` (N0 1, N1–N5 1 each, N6 2). New sha256
   `5d57b605…f5a29`. `caddy validate` reported `Valid configuration`, followed
   by `caddy reload`. The N7 imports were unchanged.

`tools/package_demonstrator.py` was not used.

## Production checks after the reload

Served `/demonstrator` sha256: N0–N5 `10678726…`, N6 `cbbe0eef…`. N7 is
unchanged at `c1096c3c…`.

**Browser test against production** (no `CANDIDATE_HTML`,
[`terminal-output-production.json`](terminal-output-production.json)):

| Node | 7 stream cases | 5,000-line burst, max round trip | Abort under flood: max round trip / abort frame seen |
|---|---|---|---|
| N3 | pass | 31 ms | 31 ms / 186 ms |
| N4 | pass | 74 ms | 74 ms / 875 ms |
| N5 | pass | 19 ms | 20 ms / 24 ms |

N4 reruns gave abort frames seen at 828, 915 and 734 ms, with flood round
trips of 82–130 ms. The test's figure includes Playwright's click handling and
the delivery of CDP frame events during the flood. Measured inside the page
([`abort_inpage.cjs`](abort_inpage.cjs),
[`abort-inpage-production.json`](abort-inpage-production.json)), the time from
the click event to `WebSocket.send` of the abort was **0 ms in all 9 runs**
(N3, N4 and N5, three runs each). The page sends the abort synchronously.

N0 and N1 are not covered by the stream test: their nodes reject `write/1`
(and N0 rejects `member/2` and `is/2`) on the node side. This is
their node policy and does not depend on the page.

**Other production checks:**
- N2 ISOTOPE and SWI-WASM spot checks were the same as with the candidate
  ([`spotcheck-production.json`](spotcheck-production.json)).
- N6 loads with its host config, and `X is 6*7` gives `X = 42`.
- N1 loads, and `X is 6*7` gives `X = 42`.
- The N0 page loads with no page errors.
- `/discovery-hub` returns 200 and the hub page shows the nodes up.
- `/tutorial`, `/manual`, `/vendor/jquery.terminal.min.css` and
  `/swipl-bundle.js` return 200 on N1, N3, N5 and N6.

## Incident: N5 unresponsive 14:02:35–14:07:27 UTC

After verification, the Discovery Hub showed N5 as down. N5 recovered by
itself after about five minutes. Nothing was changed, restarted or rolled back.

**Cause:** the endless-output flood/Abort tests run against production N5
during verification. The release did not cause it. The last of these tests
was three in-page runs of `between(1,inf,I), writeln(I), fail.` with Abort
([`abort_inpage.cjs`](abort_inpage.cjs)), ending at 13:57:31.

Evidence, from the `deployment-n5_admission-1` access log and Docker health
state:

- The hub's probes from `172.18.0.1` (`/node_info` and `/readyz` every
  30 s) returned 200 continuously through the Caddy reload and the tests, up
  to 14:02:00. N5's API traffic does not pass through the static root.
- N5 runs with `WP_IDLE_LIMIT=300`. 13:57:31 + 300 s = 14:02:31, and the stall
  began at 14:02:35. This matches the idle reaping of the aborted flood
  sessions.
- From 14:02:35 to 14:07:27 every hub `/node_info` probe ended `499`, because
  the client gave up on it. `/readyz` got no answer, and the admission
  healthcheck was rejected with `429`, because the `n5_per_client` connection
  zone was filled by hung requests. `deployment-wp_n5-1` and
  `deployment-n5_admission-1` both reported `unhealthy`.
- The Trealla process was nearly idle (under 1% CPU) at 885 MiB of its 1 GiB
  limit, with no OOM kill and no restart (`RestartCount` 0, started 07:58).
  It appears to block while tearing down sessions with large queued output,
  and then resumes.
- From 14:07:27 all probes returned 200 (`/node_info` about 40 ms), and both
  containers were `healthy` again.
- N3 and N4 ran the same flood tests and stayed responsive (about 45 ms)
  throughout. Only N5 (Trealla) was affected.

This is a stronger N5 form of the open issue in the brief, where Abort takes
effect late under heavy output. The fix belongs in trealla-port: drop or bound
queued output after an abort or a closed connection, rather than tearing it
down in one blocking step. Not done here.

**Mitigation:** `tests/wasm/terminal_output_browser.cjs` now skips the
flood/Abort check on N5 unless `TERMINAL_FLOOD_N5=1`. The stream cases and the
bounded 5,000-line burst still run on N5. After the change, the test was
re-run on N3 only and passed. N5 was left at 885 MiB resident and was not
restarted.

## Rollback

The old root `uri-20261117` is untouched, and both roots are kept. To roll
back, copy the private predecessor Caddyfile
(`.trinity/terminal-batching-20261123/private/Caddyfile.predecessor`, sha256
`dd2bdf66…`) back to `/etc/caddy/Caddyfile` in `deployment-caddy-1`, then
`chown 502:20`, `chmod 600` and run `caddy reload --config
/etc/caddy/Caddyfile --adapter caddyfile`. The exact sequence is in the
private `RELEASE-PLAN.md`.

## Not changed / follow-ups

- N7's page comes from its eclipse-node adapter package. It already streams
  and batches output but lacks the 1,000-entry logger cap. Add the cap in the
  next N7 asset package; this release did not need one.
- From the brief, still open: Abort taking effect late under heavy output in
  swi-prolog-node, and "Computation aborted." showing after `true.`.
