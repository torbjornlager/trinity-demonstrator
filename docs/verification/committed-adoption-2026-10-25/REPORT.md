# Commit-pinned local adoption — 25 October 2026

The authorised bounded adoption is complete. n3/n5 now run exact committed
implementations and serve the selected committed demonstrator assets at the
existing URLs. Local character-list reading is enabled on n3 and retained on n5.
The engine installations and repository access have not changed. Nothing was
pushed in this batch.

## Selected commits and separate repair history

| Selection | Exact revision |
| --- | --- |
| Native SWI dependency | `abbc56f3d5104bd6d40d2ed5f99fe6199d75c4a8` |
| Trealla node | `e7c51dc101cd8002dea9548f8154fc4d2bf6707d` |
| Demonstrator | `5b4deb3aeee6e3b9bc66592d0554e4e1e65535ad` |

Native repairs were committed separately as `f0fe9f2` (cyclic answers/exceptions)
and `34a8c3b` (character-list term output); `abbc56f` records diagnostic/checkpoint
documentation. Trealla repairs are `96a656f` (cyclic answers), `c6d91e2` (write/1)
and `88f89d1` (private-source shadowing), followed by `e7c51dc` documentation.
Demonstrator portal identity (`c6c8a0b`), model/Jev boundaries (`19ac6f7`), manual
qualifications and deployment records were also committed separately. Pin update
`9e536f9` selects the native revision above. Test-only `5b4deb3` aligns two smoke
checks with the intended runtime-aware greeting; production files are identical
to `9e536f9`. Historical reports remain intact, including their original failures.

[selection.json](selection.json) records the detached checkouts. Subsequent
results/documentation commits do not move the selected checkout HEADs. The
original repositories remain the maintenance locations; deployment clones are
not another place to develop fixes. These revisions are locally available;
they must be pushed before another computer can fetch the new pin.

## Exact-commit checkpoint

| Checks | Outcome |
| --- | --- |
| Native LINT, T0, T1_NATIVE, T2, T3_NATIVE, T4_NATIVE, T5 | Pass |
| External-asset T1/T3/T4 integration and origin audit | Pass |
| Default startup, pin, CI runner and browser equivalence | Pass |
| TEXT in default and chars; full native T4 in chars | Pass |
| Trealla complete unit driver on unchanged v3.14.10 | Pass |
| Default model/Jev suites and new text checks in both modes | Pass |
| Final complete WASM tier, including JS smoke/contracts | Pass |
| Runtime-aware portal identity regression | Pass |
| Startup revision/clean-input guard tests | 4/4 pass |
| Public post-restart native interoperability | 29/29 pass |
| Additional Unicode/private-source/service boundary checks | 10/10 pass |
| Real n3 text UI and n5 drawer/plain ping-pong UI | Pass |

Native and integration checks ran against the clean committed native revision;
an independent detached checkout ran both text configurations. The Trealla unit
driver ran its clean selected revision, and detached checkouts were used for
startup, application and final browser checks. No assertions or timeouts were
relaxed. Model/Jev checks use mocks; providers remain unconfigured on live n3.
This is an adoption checkpoint, not a rerun of every historical shared baseline
pack or a claim that untested GNU/browser capabilities now exist.

The first pinned CI attempt passed its native/integration checks but failed to
launch JavaScript because `node` was absent from PATH. The retry used the app's
bundled Node.js and exposed an outdated structural greeting assertion: it expected
a hard-coded SWI link and the previous readiness assignment. The separate test-only
commit updates those two source-spelling checks while retaining profile, node,
link, logo and readiness checks. The executable runtime-identity regression also
passes. A final full WASM tier rerun at the selected demonstrator commit passes.
Original failed logs are retained; [SUMMARY.json](SUMMARY.json) records resolution.

Logs for pinned integration are in [pinned-integration](pinned-integration/).
`WASM-final.log`, `RPC-bridge-retry.log`, `portal-runtime.log`,
[service-checks.json](service-checks.json), [startup-guard-checks.json](startup-guard-checks.json),
[interop-checks.json](interop-checks.json), [text-smoke.json](text-smoke.json) and
[ui-checks.json](ui-checks.json) retain the evidence. Native both-mode/T4 and
Trealla full-unit logs reside in the corresponding node repository's
`docs/verification/committed-adoption-2026-10-25/` directory.

## Startup, preservation and rollback

- n3: <http://localhost:3053/portal>, SWI, PID **13773**.
- n5: <http://localhost:3060/portal>, Trealla backend 3062, PID **13791**.
- Frontend PID 91509 and auxiliary listener PID 97669 are unchanged.

Durable deployment directory:

```
~/.local/share/trinity-local-nodes/committed-adoption-2026-10-25/
```

The usual `~/.local/share/trinity-local-nodes/n3/start.sh` and `n5/start.sh` select
these checkouts. `verify.py` rejects another HEAD, tracked-file changes or
untracked runtime/application inputs, and verifies the selected engine target
and hash. The local launchers fix the verified engine selection. Source/module
origins use the strict demonstrator pin; its validator was not bypassed or
relaxed. Normal demonstrator setup was regenerated with the selected native
checkout, so its default loader also validates the new pin.

n3 explicitly selects `WP_EXPERIMENTAL_TEXT=portable-text-0.2`. Host/library
modules retain native strings; package defaults and the cumulative language
baseline are unchanged. Six assembled browser Prolog payloads compare byte-for-byte
with the preceding payloads; the new directory hash reflects selected paths.
Browser reading semantics were not changed.

Both candidates passed temporary-port startup, shared DB, character-list and
complete ping-pong checks before the public restart. Existing node settings compare
equal. SIGTERM stopped the preceding backends; no forced kill was needed. The
post-restart checks and actual UI then passed. Old sessions ended with restart;
reload portal tabs before testing.

Previous normal launchers are retained as `n3-rollback.sh` and `n5-rollback.sh`
inside the durable directory. They select the preceding frozen code, with its
existing engines/configuration and character-list mode. Earlier native-string
rollback and all previous snapshots remain intact. To roll back a node, stop only
its recorded current backend, restore its normal launcher from the matching
rollback script and start it; do not create a second listener on the same port.
The n5 frontend can remain running. Automatic per-node rollback is also present
in the adoption script for startup/check failure; none was required.

[before.json](before.json), [preflight.json](preflight.json), [restart.json](restart.json),
[preservation.json](preservation.json), [source/engine selections](selected-code.json)
and [final processes](final-processes.txt) record provenance. Helper scripts and
copies of the selected launchers/guard are retained. Preparation scripts are
historical, single-use recipes: they refuse an existing deployment directory.

## Separate diagnostics and deferred scope

Trealla cyclic-exception copying and supplementary-character JSON surrogate
escapes (#1181) remain unresolved. Raw browser-style Unicode succeeds; the
escaped-form diagnostic remains explicit. Broader portable-text adoption,
cyclic application messages, ISO-mode diagnostics, browser text migration,
public deployment and deployment packaging are separate work. These findings
are not counted as passes, suppressed, or repaired in this adoption batch.
Retained native copies and book examples remain unchanged. No history rewriting,
repository access change, engine installation, remote publication or upstream
message occurred.
