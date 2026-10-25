# Controlled n3/n5 character-list deployment — 25 October 2026

The authorised controlled restart is complete:

| Node | Portal | Runtime | Reading | New backend PID |
| --- | --- | --- | --- | ---: |
| n3 | http://localhost:3053/portal | Existing verified SWI 10.1.18 build | Character lists, `portable-text-0.2` | 8855 |
| n5 | http://localhost:3060/portal | Existing Trealla v3.14.10 | Existing character lists | 8862 |

n3 now reads `"abc"` as `[a,b,c]`, including submitted goals, private source and
shared-database source. Host/library modules retain native strings. This enables
the previously experimental configuration on this explicitly authorised local
node; it does not change the package default, repository pin, browser engines or
language baseline. Existing sessions are lost on backend restart; reload the
portal before testing.

## Code and configuration

The native SWI snapshot now includes the tested actor term-output repair and
its isolation exclusion. The preceding cyclic-answer guards are retained. The
model/Jev application modules and dependencies are frozen with the repaired
text conversions; public shared-DB wrappers load them from that snapshot.
The current actor/statechart assets remain served at their existing URLs.
Trealla's runtime Prolog files already matched the tested working candidate;
its backend was restarted from a new durable snapshot, without an additional
Trealla runtime-code change. Native SWI application services are not installed
as Trealla-native services by this operation.

The existing n3 auth, profile, sandbox, time limits, shared DB file contents,
resident services, tutorial selection and URL configuration compare equal
before/after. The new reading mode is the intentional change. n5's node-info
configuration also compares equal. Both candidates passed temporary-port
startup, character-list and shared-DB checks before either public backend was
stopped. Both old backends stopped with SIGTERM; no forced kill was needed.

Engine binaries, installed targets, matching Trealla libraries and the
repository dependency pin are unchanged. The n5 frontend (PID 91509) and
auxiliary Trealla listener on 3061 (PID 97669) retained their original process
identities/start times. This batch changes local deployment, not installation.

## Verification

All **29 interoperability smoke checks**, **10 additional text/service checks**
and both actual browser portal text checks pass. The temporary-port preflight
adds four passing startup checks. The public checks cover:

- Correct SWI/Trealla runtime identities and functioning portal URLs.
- Cyclic-answer rejection, finite results after internal cycles and SWI cyclic
  exception rejection.
- Existing shared printer-authorization facts.
- Synchronous toplevel paging and cleanup; statechart startup, halt and down
  delivery; RPC paging and promise callback/retry/sharing/cycle rejection in all
  four native caller/peer combinations.
- Character-list Unicode/empty literals, private-source reading and actor message
  copying on both nodes.
- n3 model/Jev acceptance of character-list prompts and rejection of invalid
  inputs. Providers remain unconfigured: accepted prompts report the existing
  explicit unavailability outcomes. No paid provider call or mock-provider
  configuration was installed on the live nodes. Mock reply and JSON boundary
  verification remains in the preceding model/Jev report.

The browser checks visibly returned `[a,b,c]` and `X = [a,b,c].` from
`X="abc", X==[a,b,c], write(X).` on both nodes. n3 also supports the appended
`nl/0`; Trealla's existing sandbox rejects `nl/0`. That separate I/O difference
was recorded without changing its sandbox or claiming general I/O parity.

The known Trealla JSON-library supplementary-character diagnostic (#1181)
remains: Python's ASCII-escaped JSON form fails for a supplementary character
inside source text on n5; n3 accepts it. Browser-style raw-Unicode JSON passes
on both nodes, with unchanged assertions. The text smoke explicitly uses that
serializer, and the escaped-form failure is preserved in a separate diagnostic
file rather than counted as a passing check. No engine patch was installed.

This is a deployment smoke checkpoint, not a new full conformance-suite run.
The preceding candidate regression evidence remains applicable to the identical
runtime/application files. Broader portable-text and cyclic-exception findings
remain separate.

## Recovery and records

Durable snapshot/launcher directory:

```
~/.local/share/trinity-local-nodes/portable-text-live-2026-10-25/
```

The normal `~/.local/share/trinity-local-nodes/n3/start.sh` and `n5/start.sh`
select the new snapshots. The original launchers and old source snapshots remain
available. `n3-rollback.sh` selects the previous native source and native-string
mode, with an independently frozen committed application baseline rather than
loading the edited service working copies. `n3-previous-launcher.sh` preserves
the exact preceding launcher. `n5-rollback.sh` selects its exact preceding source
snapshot and engine. Stop only the relevant current backend, restore its normal
launcher from the rollback script and relaunch it; do not create a second listener
on an occupied port. The frontend can remain running. Rollback launchers were
prepared but no rollback was necessary or executed.

[Restart record](restart.json), [before](before.json), [after](after.json),
[source hashes](source-hashes.json), [preflight](preflight.json),
[interoperability smoke](smoke.json), [summary](checks.json),
[text smoke](text-smoke.json), [UI observations](ui-checks.json), and
[separate Unicode diagnostic](separate-unicode-diagnostic.json) retain the evidence.
No commit or push was performed in this restart batch.
