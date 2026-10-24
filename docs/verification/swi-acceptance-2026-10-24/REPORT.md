# Side-by-side SWI acceptance checkpoint — 24 October 2026

## Decision

**Keep n3 on its existing runtime for now.** The staged runtime, upstream tests,
complete native/integration tiers and temporary-node UI checks pass. However,
one of ten fresh targeted timeout-callback trials stalls and reaches its original
30-second outer watchdog. This reproduces the previously recorded diagnostic;
it was unresolved at this checkpoint. The subsequent [callback-stall investigation](../swi-callback-stall-2026-10-24/REPORT.md) identifies a swallowed HTTP-server shutdown exception and reproduces it without Web Prolog. At the time of that investigation no repair had been applied. The subsequent [separate HTTP shutdown candidate](../swi-http-shutdown-2026-10-24/REPORT.md) passes its bounded regression and cleanup checks and has been submitted upstream as [#176](https://github.com/SWI-Prolog/packages-http/issues/176). Installed runtimes and n3/n5 remain unchanged. A successful full T4 run and the other
nine passing trials do not erase it.

No existing installed SWI or Trealla runtime was modified. Live n3 and both
Trealla backends/frontends remain unchanged. The temporary node and its two
agent-created browser tabs were stopped/closed after verification.

## Exact runtime and complete staged installation

Core source commit: `09b6299f696574c9230f23e53b1ab041a942b6f3`, including Jan's
protected-wait fix. It reports SWI 10.1.18. Version alone does not establish the
fix: the ordinary macOS package reporting 10.1.18 predates this commit. The
existing long-running n3 process still reports 10.1.17; it was not restarted.

The previously tested PCRE-enabled build was installed with its original CMake
install rules into a new, previously absent private prefix:

`~/.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/install`

Executable: `install/bin/swipl`. This is a complete installation of this
candidate's configured packages, not a copy of its small executable alone.
No rebuild, source patch, global PATH change, default-runtime switch or application
bundle replacement was performed. Build-tree executable/shared-library and CMake
cache hashes remain unchanged.

Checks of the staged prefix establish:

- The runtime home resolves inside `install/lib/swipl`, without a SWI-home override.
- PCRE and SGML resolve to the staged package files; Unicode PCRE capture and XML
  parsing pass from a foreign working directory.
- Installed SSL/crypto load successfully, initialize a client SSL context, and
  compute the expected SHA-256 hash. This is not an external TLS handshake or
  certificate-validation acceptance claim.
- All installed symlinks resolve within the new prefix.
- Linkage inspection covers 28 installed Mach-O objects. No dependency or runtime
  search-path reference points back to the build tree or the installed SWI app/
  framework. System libraries/frameworks remain normal dependencies.

The first runtime probe prints an unbound `ssl_probe` error variable because
`use_module(library(ssl))` succeeded without entering its catch handler. The
explicit subsequent SSL/crypto probe supplies a clearer success marker; this
was not an SSL failure. Both records are retained.

`installed-manifest.json` records all installed file hashes;
`installed-symlinks.json`, `installed-linkage.json`, `installed-runtime-probe.log`
and `installed-ssl-probe.json`/`installed-ssl-foreign.log` provide the checks.
The original build remains separately available.

## Automated results

| Check | Result |
| --- | --- |
| Supported upstream SWI CTest groups, original build tree | **66/66 pass** |
| Staged PCRE/XML runtime probe | pass |
| Staged SSL-context/crypto probe | pass |
| LINT | pass |
| T0 | pass |
| T1_NATIVE | pass |
| T2 | pass |
| T3_NATIVE | pass |
| T4_NATIVE, all 983 scheduled cases | pass |
| T5 | pass |
| T1_INTEGRATION | pass |
| T3_INTEGRATION | pass |
| T4_INTEGRATION | pass |
| T4_LEGACY_LAYOUT | pass |
| Fresh timeout-callback case | **9/10 pass; trial 04 watchdog timeout** |
| Fresh supervisor-shutdown case | **10/10 pass** |

The upstream CTest run uses the original build-tree test definitions and
executable. All port tiers and targeted repetitions use the **staged installed
executable**. Each tier runs in its own process. Native/integration tiers run in
`swi-prolog-node`; legacy-layout checks run in the demonstrator. Integration
asset paths point explicitly to the demonstrator. Existing T5 uses disposable
fixtures, not n3/n5.

There is no newly skipped tier. Original upstream condition gates remain in
force, including the PCRE package's upstream-blocked `wb_2` case; CTest group
success does not mean every conditionally disabled internal assertion ran.
The broader WASM/experimental MODEL/JEV selections were not rerun in this native
checkpoint; the existing split native/integration catalogue above is the scope.

`run.py` records every command, working directory, duration and exit status in
`results.json`. No failed trial is retried. The selected test predicates and all
assertions/internal timeout values remain unchanged. Tiers retain the previous
300-second outer process watchdog; targeted cases retain 30 seconds. Upstream
CTest uses its own original test properties with a 900-second emergency process
group watchdog, which did not fire. No CTest per-test timeout was overridden.

## Remaining callback diagnostic

The failing case is exactly:

`node:isobase_yield_timeout_callback_is_sandboxed`

Trial `callback-04.log` prints its test-start marker and then makes no further
progress before the unchanged 30-second watchdog terminates that disposable
process group. It does not produce a failing assertion or a completed sandbox
error response. All other targeted callback trials pass, as does the same case
within the complete T4-native suite. Each targeted trial runs in a fresh process,
serially, with no failure retry.

The test starts a temporary ISOBASE/blacklist node. Its HTTP query makes a promise
to that node and attempts `yield/3` with an unsafe `nb_getval/2` timeout callback.
The existing assertion expects an error response containing `sandboxed`.
This checkpoint does **not** determine whether the stall is in promise handling,
HTTP completion, callback admission, cleanup, the test fixture, or the engine.
No native stack trace or standalone reproducer was collected. Do not label it
an upstream engine bug, an installation fault or harmless timing based on this
log alone. The same named diagnostic was recorded in the earlier build-tree
split-layout/extraction runs, before staging this installation.

The next bounded step is a test-only trace of this case under the same assertions
and deadlines, distinguishing request submission, callback rejection, response
writing and fixture cleanup. Runtime repair and live-node cutover remain separate.

## Actual temporary-node UI checks

A loopback-only ACTOR node on **51853** used the staged executable and the
`swi-prolog-node` runtime, with external demonstrator assets and the common,
actor-common and n3 shared database sources. It advertised its own temporary
URL and allowed only that temporary origin. No connection to live n3/n5 or a
public remote node was used for the UI exercises.

Through the real portal editor/terminal controls:

1. `runtime_property/1` reports `swi_native`; synchronous toplevel call/next return
   `[a,b]` with more answers, then `[c]` terminally; halt completes.
2. A throwing parallel worker produces `ui_error`, and before/after actor lists
   match exactly. Timed receive returns `waiting` while preserving an unrelated
   queued `kept` message.
3. URI XML source starts from the temporary node's example endpoint; statechart
   halt and exact spawn-monitor notification complete with reason/reply `true`.
4. UI **Abort** interrupts two workers blocked in receive. The next query confirms
   only the session actor remains, then successfully creates/counts/halts an empty
   supervisor.
5. Editor source `probe(ok).` is loaded into a new private session. `probe(Value)`
   returns `ok`; inline XML statechart startup and halt succeed.
6. A promise over HTTP to the temporary node returns `Early=waiting` through its
   timeout callback, then retry returns `Answer=success([ok],false)`.

The ACTOR tutorial also renders correctly from the staged node, including the
synchronous-wrapper section and example buttons. This was a rendering check;
tutorial Call buttons were not exercised in that separate tab. The actual queries
above were submitted in the portal terminal, and editor source was entered
through its editor control. Expected worker-kill/abort notices remain in the
transcript rather than being suppressed.

Evidence: `ui-node-command.json`, `ui-node.log`, `ui-transcript.txt`,
`ui-final-transcript.txt`, `ui-final.png`, and `tutorial-rendered.txt`.
The staging probe covers PCRE directly; no extra PCRE UI predicate exposure or
sandbox exception was introduced to obtain a UI pass.

## Preservation

`before.json`, `after.json` and `final-preservation.json` confirm:

- Installed app/framework SWI executables are byte-identical.
- Both retained and active Trealla executables are byte-identical; active Trealla
  library hashes also match before/after the automated run.
- n3 PID 55051, Trealla frontend PID 42134, public backend PID 97896 and auxiliary
  backend PID 97669 retain their original commands.
- Runtime and test Prolog/shell files in both repositories are unchanged.
- The fixed build's binary/cache hashes, core revision and clean tracked source
  status remain unchanged.

Only this verification directory was added. The new private installation prefix
is retained for further checks and a later explicitly authorized cutover. The
existing live runtime selection has not changed. No commit or push is performed
by this checkpoint.

The one-off staging driver refuses an existing install prefix. Preserve this
verified prefix and its evidence rather than rerunning the installation driver
against it. `start-ui.py` and `finish.py` record the temporary-node lifecycle;
`finish.py` stops only its recorded owned PID after checking the command.
