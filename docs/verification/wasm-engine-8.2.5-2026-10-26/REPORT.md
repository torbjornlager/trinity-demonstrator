# Separate SWI-WASM engine acceptance — 26 October 2026

The latest published `swipl-wasm` package, **8.2.5**, contains **SWI-Prolog
10.1.19**. It passes the existing full WASM tier in an isolated export, with
unchanged Web Prolog adapters, assertions and deadlines. Browser checks in both
execution modes found no demonstrated new engine regression. A statechart
monitor wait fails on both the candidate and the old-engine control and remains
a separate, unresolved adapter diagnostic.

**The candidate has not been installed or served by the running demonstrator.**
Native runtimes, n3/n5, the selected browser assets and the old bundle are unchanged.

## Inputs and isolation

- Demonstrator export: committed `dc1b3d1cfe735c81372515991fb27397478ba770`.
- Candidate: official npm package `swipl-wasm@8.2.5`; registry SHA-512 integrity
  verified before extraction. [Registry metadata](package.json),
  [download/source provenance](provenance.json).
- Candidate engine queried directly: `swi(10,1,19,[])`, git `10.1.19`.
- Current served engine queried directly: `swi(10,1,8,[])`, git
  `10.1.8-5-ga827ea8b3`. The served bundle's hash matches the retained frozen copy.
- The isolated export differs in exactly one tracked file:
  `web/swipl-bundle.js`. [Comparison](isolated-diff.json).
- Candidate files are retained separately under
  `~/.local/share/trinity-runtime-tests/wasm-engine-8.2.5-2026-10-26/`.
  No installed executable, repository bundle or running node was replaced.

Official upstream [8.2.5 build configuration](https://github.com/SWI-Prolog/npm-swipl-wasm/blob/v8.2.5/build-config.json)
identifies core commit `724df2b54cf1dda6fb3327d9167db2ae750c460e`,
Emscripten 6.0.13, zlib 1.3.2 and PCRE2 10.49.0. Package and engine version
numbers are intentionally different.

## Full unchanged tier

The separate export ran:

```
python3 tools/ci_timeout.py 360 -- bash tools/test.sh WASM
```

It used official separate Node **22.23.4** and the existing separate official
native SWI **10.1.19** launcher for the native statechart portion, with
`WP_NATIVE_MODE=legacy`. Neither changed an installed runtime. The tier passed
in **182.476 seconds**, exit **0**, with **2,751 semantic `ok` lines** and
`all scenarios passed`. It includes the shared-statechart equivalence guard,
native statechart tests, Worker/coordinator bridge smoke checks and real-engine
contracts for both browser execution models. Assertions, sleeps, timeouts,
scenario selection and the 360-second watchdog are unchanged.

[Full log](WASM.log), [command and host versions](wasm-results.json),
[summary](summary.json). This is local macOS acceptance, not a hosted CI run.

## Actual browser UI checks

The candidate was served by an ephemeral loopback node, using the clean frozen
native source `abbc56f3d5104bd6d40d2ed5f99fe6199d75c4a8` and the same selected
native engine as n3, without sending test queries to n3. Browser Prolog support
files are the unchanged six-file payload selected by the live demonstrator.
The temporary HTTP peer also handled the browser's RPC and promise checks.
The old-engine control uses identical frontend files with the old bundle in a
second isolated asset root and another ephemeral node.

`serve_candidate.py` records commands, asset roots and node identities in
[the candidate record](ui-node.json) and [old control record](old-control/ui-node.json).
CUA used only the public portal, terminal, input prompt and Settings controls;
no runtime state was inspected using browser JavaScript evaluation.

| Identical candidate assertion | Worker | Main thread |
|---|---|---|
| e001: engine reports exactly 10.1.19 | Pass | Pass |
| e002: character-list, empty, supplementary Unicode and DCG terminals | Pass | Pass |
| e003: private source and ordinary actor monitor delivery | Pass | Pass |
| e004: parallel out-of-order completion | Pass | Pass |
| e005: first-solution loser cleanup | Pass | Pass |
| e006: worker exception cleanup | Pass | Pass |
| e007: promise timeout callback and subsequent retry | Pass | Pass |
| e008: HTTP paging across two slices | Pass | Pass |
| e009: statechart halt followed by `down(P,P,_)` | Baseline diagnostic | Baseline diagnostic |
| e010: strict Boolean option validation | Pass | Pass |
| e011: write output and successful answer | Pass | Pass |
| e012: supplementary Unicode terminal input | Pass | Pass |
| e013: statechart startup and halt acknowledgement | Pass | Pass |

That is **12 passed and one retained diagnostic per mode**, not 13/13.
Separate actual queries `write("abc"),fail.` and
`write("abc"),throw(candidate_output_error).` print `[a,b,c]` before failure
or the exception in both modes. The unchanged semantic tier additionally
covers success-output ordering.

[Executed goals and compact verdicts](ui-results.json),
[compressed complete UI states](ui-evidence.json.gz),
[Worker screenshot](worker-ui.png), [main-thread screenshot](main-ui.png).
Output-order evidence is in the four `*-output-failure.ax.txt` and
`*-output-error.ax.txt` files.

The original e010 assertion catches the exact expected type error and requires
an unbound pid. The e009 two-second wait and exact receive pattern are retained;
no failure was converted to a pass by broadening it. A later acknowledgement
control is separately identified as e013. Its first Return was blocked by an
open Settings popover; the pending query was submitted after closing that
popover and the saved result is the completed assertion.

## Statechart monitor diagnostic — unchanged by the engine update

Both engines produce `missing_chart_down` for:

```
statechart_spawn(P, [
    src_text('<statechart version="0.2" initial="s"><state id="s"/></statechart>'),
    trace(false), monitor(true)
]),
statechart_halt(P, Reply),
Reply == stopped,
receive({down(P,P,_) -> true},
        [timeout(2), on_timeout(throw(missing_chart_down))]).
```

The old-engine Worker and main-thread controls confirm version 10.1.8 and the
same timeout; see `old-control/*statechart.ax.txt`. Candidate e009 captures the
corresponding 10.1.19 result.

In Worker mode, separate broad diagnostic receives show that a notification
**is delivered**, but its first pid field has an `@localhost` qualification
while the returned pid and monitor reference do not. Canonical spelling is
retained in `worker-reference-encoded.ax.txt` and
`old-control/worker-reference-encoded.ax.txt`: e.g. candidate `DT` includes
`7910453821@localhost`, whereas `PT`/`RT` contain `7910453821`. This explains why
the original exact pattern does not select it. UI pid hiding makes these values
look identical; the structured public API log preserves the distinction.

In main-thread mode, even a separate broad diagnostic receive times out; its
complete cause has **not** been established by this acceptance batch. The saved
main reference probes retain that result. Statechart creation and the `stopped`
acknowledgement work on the candidate in both modes. These observations locate
a pre-existing browser statechart monitoring problem; they do not justify an
engine repair or a claim that all statechart lifecycle behavior passes.

The splash screen reports the temporary native asset host's version (10.1.18),
and a loading message contains an old build date. Neither identifies the WASM
engine. Direct flag assertions and visible `version_data` answers identify the
candidate as 10.1.19. Those existing UI metadata issues were not changed.

## Preservation, recommendation and reproduction

[Preservation](preservation.json) compares all four protected process identities,
selected native binaries and launcher/asset selection hashes, the repository
bundle and the live served bundle against [before](before.json). All match.
Both test nodes were stopped and both agent-created tabs closed; stopped-node
records are retained. No runtime source or live configuration was edited.

The candidate is suitable for a **separate controlled bundle-update decision**:
the full unchanged tier passes and the UI diagnostic reproduces with the old
engine. The statechart monitoring issue should receive its own bounded adapter
investigation; this report neither fixes it nor treats it as an engine-update
regression. Keep the old bundle and its hash for rollback when an update is
explicitly authorised.

To repeat the tier, recreate the committed export in a fresh directory, verify
the npm tarball against the recorded integrity, replace only its bundle, and run
the recorded command with the recorded Node/SWI paths and environment.
`serve_candidate.py` documents the local temporary-node setup; its optional
`TEST_WASM_WEB_ROOT` and `TEST_WASM_EVIDENCE` variables select an alternate
isolated root/output for the old control. Use fresh evidence output, open its
printed portal URL in each mode, and run the goals in `ui-results.json`.
Creating `STOP` in that evidence directory stops only its recorded fixture.
`verify_evidence.py` checks the saved results without starting a node.
