# Release brief — terminal output batching (23 November 2026)

Handover from the cloud session to a Claude Code session on the Mac, which can
reach the live nodes, run Chrome and `tools/test.sh`, and use the deploy
operators. The cloud session could do neither.

## State at handover

| Repository | Ref | Commit |
|---|---|---|
| trinity-demonstrator | `main` (live) | `00ad413` |
| trinity-demonstrator | `terminal-output-batching` (this change) | `95511b1` + this brief |
| swi-prolog-node | `main` | `67f0b17` |
| trealla-port | `main` | `2924726` |
| swi-wasm-node | `main` | `1d6ee0d` |
| eclipse-node | `main` | `cbe235c` |

Remote branch cleanup is done: the demonstrator has only `main` plus this
branch. Unmerged old branches are kept as `archive/*` tags
(`archive/codex/restore-terminal-ui` is the source of this port). The tag
`n7-pilot-v0.1.0` was pushed incidentally; harmless, the owner may delete it.

## The change (UI only, `web/demonstrator.html`)

Problems on live N3 and N5 (`main`, measured 23 November):

1. Program output was shown one wire message per line: `write(a),write(b)`
   printed `a` and `b` on separate lines; `nl,nl` printed four blank lines.
   The nodes send the exact text in each `output` message's `stdout` field.
2. Output bursts froze the page. Each `term.echo` cost about 14 ms, and each
   message re-rendered the unbounded logger (about 9 ms at 2,000 entries).
   1,000 lines took 29 s with a 24 s freeze; 20,000 lines blocked Abort for
   minutes.

Fix:

- `queueNodeOutput` / `flushTerminalOutput`: output is rendered every 50 ms,
  at most 500 lines per tick (`TERMINAL_OUTPUT_FLUSH_MS`,
  `TERMINAL_OUTPUT_BATCH`). `stdout` chunks are written as one stream
  (`echo(text, {newline: false})`). `finishSuccess`, `finishFailure`,
  `finishError`, `showPrompt` and `echoTerminalCommand` flush first;
  `clearTerminal` discards pending output.
- `log` / `flushLogEntries`: logger entries are added in the same batched way
  and the list keeps the newest 1,000 (`LOGGER_MAX_ENTRIES`). Both logger
  clear paths discard pending entries.
- Nodes without a `stdout` field (possibly N6, N7, older ISOTOPE paths) keep
  the previous one-line-per-message display.

Verified so far only by injecting the patched methods into the live N3 page:
all 7 stream cases correct; 2,000 lines in 0.5 s with the longest pause under
0.1 s; during endless output the page stays responsive, the display keeps
pace, and `toplevel_abort` is sent 1 ms after the click. N5 sends identical
`output` messages.

## Tasks for the Code session

1. `git fetch origin && git switch terminal-output-batching` in
   `~/trinity-demonstrator`. Run `./tools/test.sh` with the explicit verified
   SWIPL (includes the WASM bridge smoke test, which slices methods out of the
   page).
2. Run the new browser test against live N3 and N5 with the candidate page:

   ```
   CANDIDATE_HTML=web/demonstrator.html \
   CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
   TERMINAL_REPORT=/tmp/terminal-output.json \
   node tests/wasm/terminal_output_browser.cjs
   ```

   It checks the 7 stream cases, a 5,000-line burst (page round trip under
   1 s, logger at most 1,000 entries) and that Abort sends `toplevel_abort`
   within 500 ms during endless output. Optionally also N4 (`TERMINAL_NODES`).
3. Spot-check by hand with the candidate page: N2 (ISOTOPE path), N6 and N7
   (no `stdout` field expected, so line-per-message display should be
   unchanged), and SWI-WASM mode (its own output path; should be unaffected).
4. If green, fast-forward `main` and push.
5. Release as a **UI-only** change (HANDOVER §9.1 table, §9–10 procedure,
   owner approval before the live switch):
   - N0–N6 pages come from the Caddy static roots `uri-20261117` in the
     `deployment_edge_assets` volume. Make a new root per node by copying the
     current one and replacing only `demonstrator.html`. First diff the live
     root's `demonstrator.html` against `main`'s `web/demonstrator.html`; if
     the live copy carries per-node host configuration, apply the same
     difference to the new page rather than shipping the raw file.
   - **Do not use `tools/package_demonstrator.py` output** for the node roots.
     On 22 November it produced a self-contained static site
     (`WEB_PROLOG_HOST mode:"static"`, `nodeUrl:null`) and broke every node
     UI (see HANDOVER, "Static assets").
   - N7 serves its own shell from its eclipse-node asset package; decide
     whether its demonstrator page needs a new asset package or can wait.
   - Repoint Caddy roots, reload gracefully, verify on every node (the browser
     test without `CANDIDATE_HTML` now tests production), keep the old roots
     for rollback.
6. Record the run under `docs/verification/` and update HANDOVER.

## Open issues found, not part of this change

- **swi-prolog-node: Abort takes effect late under heavy output.** On N3,
  `between(1,inf,I), writeln(I), fail.` then Abort: the page sent
  `{"command":"toplevel_abort","pid":…}` within 1 ms, but the node kept sending
  output for another 38 s (about 175,000 lines at a steady 4–5,000 per second)
  before its `abort` event. The page can drain about 85,000 messages per second,
  so the delay is upstream: either the abort is handled late or outgoing
  messages queue without bound ahead of the reply. Fix belongs in
  swi-prolog-node (`node_ws.pl` output path), per the repository rules. Worth
  comparing with N5 (Trealla).
- **"Computation aborted." after `true.`** Pressing Abort just as a query
  finishes shows both. Small, pre-existing display quirk.
- The logger cap is a presenter behaviour change, not a language one, so no
  `DEVIATIONS.md` entry was made; add one if the owner prefers.
