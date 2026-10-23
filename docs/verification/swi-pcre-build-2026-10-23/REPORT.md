# Separate SWI build with PCRE — 23 October 2026

## Outcome

The new separate Jan-fix build provides `library(pcre)` and passes the requested
PCRE, T5, receive-handoff and worker-cleanup checks. All nine T5 comparisons
previously blocked by PCRE now pass. No Web Prolog runtime/test code, language
manual or book example changed.

The previously tested build, installed SWI/Trealla executables and live N3/N5
processes remain unchanged. This batch creates a build-tree candidate; it does
not install SWI or replace node startup commands.

New executable:

`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl`

Preserved executable:

`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299/build/src/swipl`

## Build

- SWI core remains exactly Jan's
  `09b6299f696574c9230f23e53b1ab041a942b6f3` commit. It reports version 10.1.18;
  source revision and artifact hashes, not version alone, identify the fix.
- The original minimal explicit `SWIPL_PACKAGE_LIST` omitted PCRE, and its PCRE
  source submodule was uninitialized despite the general PCRE group option
  being ON. The new selection explicitly adds `pcre` and initializes the
  checkout's pinned package revision
  `52a0e9486c4770f2fbfac3f4fb8a1cd9e8c77af1`.
- PCRE2 release tag `pcre2-10.49` resolves to
  `6f9d7c1373262c541324a16a358785b33ef116cf`. It is built in its own source/build
  directories, with Unicode and JIT enabled and a position-independent static
  8-bit library. Its pinned SLJIT dependency is recorded in provenance.
- PCRE2 headers/library are installed only into the new private `pcre2/` prefix.
  SWI's PCRE plugin is compiled against this dependency and the new SWI build.
  The plugin linkage has no dependency on the installed SWI framework or its
  PCRE plugin; see [linkage](pcre-linkage.txt).
- SDK 15.4, Release mode and LibBF (`USE_GMP=OFF`, `USE_LIBBF=ON`) match the
  preceding separate build. The existing private static OpenSSL dependency is
  reused read-only. No global package manager or system installation was used.
- SWI's source and initialized submodules, and PCRE2's source, remain clean.
  No engine or package source patch was necessary.

Official source references: [SWI PCRE package build](https://github.com/SWI-Prolog/packages-pcre/blob/52a0e9486c4770f2fbfac3f4fb8a1cd9e8c77af1/CMakeLists.txt),
[PCRE2 release](https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.49).
All fetch, configure, build and private-install commands are in
[build.py](build.py) and [build-results.json](build-results.json).

## Verification on the new executable

| Check | Result | Evidence |
|---|---|---|
| PCRE2 CTest groups, including JIT | 4/4 pass | test-pcre2.log |
| SWI PCRE package | 160 executed tests pass; one upstream-blocked test | swipl-pcre.log, swipl-pcre-details.log |
| Direct PCRE availability, Unicode capture and global replacement | pass on corrected probe invocation | pcre-feature-probe-rerun.log/json |
| Full T0 actor tier, including receive-handoff regressions | pass | t0.log |
| Full T3 behaviour tier, including worker/supervisor cleanup | pass | t3.log |
| Complete T5 interoperability/golden tier | 20/20 pass | t5.log |
| Node worker scope, ownership cleanup and mailbox accounting | pass, final empty-mailbox check | node-worker-accounting.log |
| Worker-scope group repeated in one process | 30/30 pass, empty-mailbox check after each | worker-fixed-batch.log |
| Receive-handoff group repeated in one process | 10/10 pass | handoff-fixed-batch.log |
| Jan's upstream protected signal-wait tests | 4/4 pass | upstream-signal-wait.log/json |

The explicitly blocked PCRE case is upstream `wb_2`, marked
`blocked(javascript_compat)` in the pinned package. It was not enabled or counted
as passing. The direct probe reports PCRE2 10.49, `jit(true)`, `unicode(true)` and
the new build's own `library/ext/pcre/pcre.pl` path.

T5 uses the new executable for both the layered stack and its disposable
archived `demonstrator-peer` fixture, selected through the explicit `SWIPL`
environment variable. This is the existing tier's protocol/golden comparison;
it is not a new Trealla interoperability matrix. Its nodes are temporary and do
not replace N3/N5.

The repeated groups retain guards, ordering, variable sharing, original
deadlines, body failure/exception/nondeterminism, interruptible empty waits,
partial worker startup, worker interruption and unrelated monitor/message
checks. The new artifact was used throughout. The group repetitions are not
fresh-process trials; each named tier/group batch has its own bounded process.
Finite passing runs do not establish general race freedom or scalability.

## Retained probe invocation error

The first custom feature probe successfully loaded PCRE and printed its version,
JIT and Unicode capabilities, then failed at an `absolute_file_name/3` lookup
that omitted `file_type(prolog)`. That command exited 2. The initial result and
log remain unchanged; this was a diagnostic command error, not a failed PCRE
package test or a missing library in the new build.

The corrected probe uses the proper source-file lookup and passes Unicode
capture and global replacement checks. Its separate JSON/log record is kept.
`test.py` is corrected for future reruns. The initial main runner truthfully
reports 7/8, with that one invocation error; the corrected probe completes the
requested verification. No runtime code or expected test result was changed to
obtain a pass.

## Preservation and limits

[before.json](before.json) and [provenance.json](provenance.json) verify:

- The preserved separate SWI executable and CMake cache hashes are unchanged.
- Its core revision, source status and submodule states are unchanged.
- Installed SWI app/framework and pinned Trealla executable hashes are unchanged.
- Existing N3 PID 55051, N5 frontend PID 42134 and N5 backend PID 30612 retain
  their original command lines.
- New core, shared library, PCRE plugin, dependency and configuration hashes are
  recorded alongside exact source/package revisions.

Only this verification directory was added to the demonstrator repository.
Full SWI upstream CTest, full T1/T2/T4 and new UI/HTTP-TLS acceptance were not
rerun in this bounded batch. Existing shared-manual smoke and unmodified-Trealla
paging diagnostics remain separate. This removes the PCRE build blocker; it is
not an installed-runtime upgrade or blanket deployment certification.

## Reproduction

From the demonstrator repository:

```sh
python3 docs/verification/swi-pcre-build-2026-10-23/test.py
```

The test launcher pins the new executable and `SWIPL` environment and uses
external process-group watchdogs. `test-results.json` records exact commands,
exit codes and durations. The initial invocation's command differs from the
corrected probe in the current rerunnable script, as documented above.

`build.py` records the construction of the fresh private tree. It expects that
tree not to exist before cloning; preserve the existing artifacts and select a
new destination when rebuilding rather than overwriting this verified tree.
The source/build dependencies and output paths are explicit in its arguments
and the retained CMake caches.
