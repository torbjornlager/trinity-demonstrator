# Additional automatic-WASM CI checks — 25 October 2026

All final extended checks passed. No runtime or language-test change was needed.
The new CI job remains uncommitted and hosted Ubuntu execution is still pending
push; these checks used the same isolated Node 22.23.4 and official SWI 10.1.19
macOS package as the original verification.

| Check | Result |
| --- | --- |
| Full WASM tier in a clean exported checkout | pass, exit 0; 169.890 seconds; 2,751 `ok` assertion lines |
| Worker character-list contracts | 10/10 processes pass; 150 assertions |
| Main-thread character-list contracts | 10/10 processes pass; 180 assertions |
| Main-thread output-ordering contracts | 10/10 processes pass; 150 assertions |
| Timeout injected through the exact job pipeline | exit 124 preserved; partial log and metadata retained |
| Log-writer failure injected through the exact pipeline | exit 9 preserved; metadata retained |
| Missing SWI executable | host-shell failure status preserved; no language tests started; metadata retained |
| Existing process-group watchdog regressions | 3 tests pass |
| Existing pinned CI runner regressions | 6 tests pass |

## Clean export and repetitions

The export used committed base `290bc0312f01163f361ac1290dbd58ee7f643080`, with
the candidate workflow and README copied in. Runtime and test inputs are unchanged
from that commit. The export had no `.git`, generated `.trinity` state, or private
native checkout. External source-selection environment variables were removed,
`WP_NATIVE_MODE=legacy` was explicit, and the exact saved workflow shell step
ran against the exported files. This establishes that the WASM tier does not
rely on this working checkout's generated setup or Git history. The export was
removed after the run; evidence remains in
[the full log](clean-artifacts/wasm-ci-results/WASM.log),
[versions](clean-artifacts/wasm-ci-results/versions.log) and [results](results.json).

The three focused scenarios then ran ten times each in fresh real-engine Node
processes. All 480 assertions passed. Each iteration's log is retained alongside
this report; no test guards, timeouts or assertions were edited.

## Controlled failure cases

Only isolated temporary fixture directories used fake tier commands. The actual
repository's full tier and repeated contracts ran unchanged. The timeout fixture
used a short deadline solely to exercise exit/log propagation without waiting
six minutes. The real job's 360-second bound remains unchanged. A fake `tee`
returned 9 after draining output to prove that log-writing failure also fails the
job step. A missing executable check proved that tests cannot run after the SWI
version check fails. All fixtures were disposed.

The first missing-executable check incorrectly assumed shell status 127. This
Mac's Bash returned 1, including in independent minimal controls. The job had
correctly failed before tests. The fixture was corrected to require the same
nonzero status as an independent host-shell control, the missing-executable
diagnostic, and absence of any WASM test log. No production code or language
assertion was changed. [Original driver trace](driver.log),
[expectation record](negative-test-expectation.json),
[negative-case recheck](negative-recheck.log). The already-passing clean export
and repetitions were retained; only the controlled negative cases were rerun.

`run.py` reruns the full extended checks; `--negative-only` reruns the temporary
failure fixtures while retaining the earlier positive results. See also
[watchdog regressions](watchdog.log) and [pinned-runner regressions](pinned-runner.log).

[Preservation checks](preservation.json) confirm running process identities,
installed native executable hashes, live browser-asset selection, dependency
pin and unchanged tests/runners against the parent verification's baseline.
