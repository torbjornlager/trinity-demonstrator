# Native CI engine prerequisite — SWI-Prolog 10.1.19, 25 October 2026

## Diagnosis

The [character-list migration CI run](https://github.com/torbjornlager/trinity-demonstrator/actions/runs/40225316381)
installed SWI **10.0.2** from the stable PPA. It reported T0, T2 and T3 timeouts,
T1's URI-loading test failure, missing termination notifications and cleanup
exceptions. The run was subsequently cancelled by the newer push; it did not
pass. Neither browser change modified native actor code.

The native receive adapter requires core fix
[`09b6299`](https://github.com/SWI-Prolog/swipl-devel/commit/09b6299f696574c9230f23e53b1ab041a942b6f3).
Without it, queue waits protected by `sig_atomic/1` can spin with a pending
signal, preventing actor termination and its monitor notifications. A controlled
comparison used the existing unpatched official 10.1.18 package and the separate
fixed build. It reproduced interruption failures, a URI-test failure and a shell
stall on the former; all three passed on the latter. This was not a local run
of CI's exact Linux 10.0.2 binary. See [diagnostic results](diagnosis/results.json).

Stage probes further showed that the URI fixture successfully spawned, loaded
its source and received its count reply. It failed only after sending kill,
waiting for `down`; the fixed build delivered `down`. The errors named
`test_cleanup` were secondary cleanup errors, not evidence of a URI parser bug.
[Unpatched stages](diagnosis/unpatched_10_1_18-uri-stages.log),
[fixed stages](diagnosis/fixed-uri-stages.log).

## Bounded CI change

Both jobs now use the local composite action `.github/actions/setup-swi`. It
builds official **10.1.19**, whose
[release changelog](https://www.swi-prolog.org/ChangeLog?from=10.1.18&to=10.1.19)
includes the required fix. The release source archive and SHA-256 are fixed
explicitly; builds use its bundled package sources and a runner-temporary prefix.
There is no latest-version selection or custom core patch. Ubuntu dependencies
cover PCRE, GMP, XML/HTTP, crypto/SSL, archive and terminal support. A version and
library check rejects incomplete builds before tests.

The automatic legacy job runs the existing full receive-handoff regression
group first with a 30-second process watchdog. All original LINT/T0–T5 assertions
and 360-second tier deadlines remain. The optional pinned-native job still
requires manual selection and its existing dependency access; no pin, repository
visibility or credential settings changed. Its existing orchestration is retained.

`tools/ci_timeout.py` sends TERM to the disposable tier's process group, permits
10 seconds of grace, and sends KILL to remaining members even if the group
leader exited on TERM. It reports timeout as exit 124. This prevents an orphaned
Prolog child from leaking into subsequent tiers. Tests exercise original exit
statuses, a TERM-resistant command, and a resistant child whose leader exits.

The automatic push job still runs native tiers, not WASM. Adding automatic
browser CI coverage is separate from this engine-prerequisite repair.

## Verification

The official macOS 10.1.19 package was downloaded, checked against the published
SHA-256, and extracted into a new separate directory. The installer was **not**
run. An isolated launcher selects its extracted framework and matching library
home. The same official source archive selected for Ubuntu CI was independently
downloaded and its SHA-256 verified; it contains the bundled HTTP/SSL packages.
[Download provenance](downloads.json), [separate launcher selection](runtime.json).

All native checks below used that unmodified official macOS package, default
language mode and `WP_NATIVE_MODE=legacy`, against demonstrator base
`b9ea7c557a61faf5ef9524fb97500bbe1ff89015` plus this CI-only working-tree batch.
No test assertion or sleep was edited. `run.py` is the reproducible local
checkpoint, with the original 360-second outer watchdog and 10-second grace;
no check reached a watchdog. [Results](results.json), [runner log](runner.log).

| Check | Result | Seconds |
| --- | --- | --- |
| prerequisite | pass | 1.545 |
| libraries | pass | 0.127 |
| LINT | pass | 0.238 |
| T0 | pass | 7.277 |
| T1 | pass | 0.624 |
| T2 | pass | 6.85 |
| T3 | pass | 40.945 |
| T4 | pass | 52.298 |
| T5 | pass | 1.332 |

Additional checks: all 3 real process-group watchdog regressions passed;
all 6 existing pinned-CI runner tests passed; both workflow/action YAML files
parsed and every inline shell block passed `bash -n`. See
[watchdog tests](timeout-tests.log), [pin tests](pin-tests.log),
[workflow syntax](workflow-syntax.log).
T4's two existing output-stream closure notices did not cause failures.

**Hosted Ubuntu build/test results are pending a commit and push.** The local
macOS package results and syntax checks do not establish a successful Ubuntu
source build or a green GitHub run. No CI job was rerun or workflow dispatched
as part of this local verification.

## Preservation

[Preservation evidence](preservation.json) confirms installed SWI/Trealla
executable hashes, n3/n5 process identities, launcher hashes and runtime selection
are unchanged. No live node, dependency pin, native runtime implementation,
manual language semantics, browser code or book example was changed.
