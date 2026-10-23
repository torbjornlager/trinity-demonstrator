# Native SWI receive-handoff candidate — 2026-10-23

## Outcome and prerequisite

The candidate closes the native-dequeue to deferred-record signal window, while
keeping default empty-mailbox waits interruptible. Verification used only the
separate SWI build containing Jan's `09b6299` protected-wait fix. The installed
SWI 10.1.18 binary/framework are unchanged; no live node was restarted.

**Do not deploy this candidate on the official macOS 10.1.18 package.** It
predates Jan's fix and can spin in a protected timed wait with a pending signal.
The separate build reports the same 10.1.18 version, so the source commit/hash,
not the version number alone, identifies the prerequisite. See provenance.json.

## Change

`actors:receive_message/4` now returns the clause reference for a deferred fact
created in the same signal-atomic region as native acquisition. Once the helper
returns, an interruption leaves that fact available for the next receive.
Guards and selected bodies run outside the protected region. Message consumption
still removes the fact and calls the existing accounting hook exactly once.

Zero-time reads protect peek, native read and recording together, without a
timed wait. Other default reads wait at most 50 ms per protected slice, with
normal signal handling between retries. An unbounded public receive therefore
has bounded protected waits; it does not need a message to wake it before an
abort can run. Real native queue arrivals wake the wait immediately, without
waiting for a polling interval. Finite waits retain the original absolute
deadline and call the timeout body only after the overall deadline.

The option adapter validates via SWI itself using a forced expired deadline,
which cannot remove a queued message. It keeps native type/domain validation,
unknown-option handling and last-option precedence, and resolves relative
waits before slicing. Explicit native `signals(false)` retains its original
request to suppress signal checks while waiting; default actor waits remain
interruptible. No new public receive options or protocols were introduced.

The scope is asynchronous signal handoff. This is not a new transactional
rollback guarantee for allocation/resource failure in `assertz/2`, nor a repair
of every possible interruption boundary in quota accounting or nested guards.
Those synchronous-failure/nested-reentry cases are not newly claimed safe.
Periodic wakeups are an implementation tradeoff; no performance or scalability
benchmark is claimed.

## Checks

| Check on the separate fixed engine | Result |
| --- | --- |
| Full T0 actor tier (including new receive tests) | pass, exit 0 |
| Full T3 behaviour tier | pass, exit 0 |
| Node-level worker scope, ownership cleanup and mailbox accounting | pass on corrected invocation, exit 0 |
| Worker-scope regression group, 30 repetitions with final empty-mailbox checks | 30/30 pass |
| Receive-handoff regression group, 10 repetitions | 10/10 pass |
| Same-engine controlled baseline vs candidate | baseline 20/20 missing; candidate 20/20 preserved |
| Layering lint | pass, 531 edges checked |
| Installed executable/framework hashes | unchanged |

The ten receive-group repetitions include 800 gated post-acquisition trials
(20 trials for each of blocking, polling, timed and absolute-deadline modes per
group) and 150 empty-wait interruption trials (five per mode for blocking,
timed and absolute deadlines per group). Each empty-wait test lets the wait
start, signals `$abort_goal`, and requires a response within its one-second
host receive bound and measured elapsed time below 0.8 seconds. These are test
bounds under this workload, not a hard real-time guarantee.

Other checks cover a single timeout callback across multiple slices, expired
and negative deadlines/timeouts leaving the native message untouched, duplicate
native timeout precedence, message consumption before body failure/exception,
body and timeout alternatives, plus the existing guarded receive, variable
sharing, ordering, unmatched-arrival deadline and zero-time cleanup tests.
The node accounting test checks that native/deferred/flushed messages are
charged and released exactly once. The worker tests retain unrelated messages
and monitor checks and cover startup failure, interrupted waits, commit-time
interruption, actor termination and cuts.

The initial node command ran all its assertions successfully but then called
`ensure_mailbox_empty/0`, which T4 does not define, and exited 2. This is retained
in `results.json` and `node-worker-accounting-initial.log`; it is an invocation
error, not silently reported as a passing run or a runtime failure. The corrected
rerun uses a public `receive/2` empty-mailbox check and passes; see
`node-worker-accounting-rerun.json` and its log. The rerunnable script has the
corrected command.

Early test-development drafts with a wrong native thread_get_message arity or
an obsolete comparison-module export were corrected before the retained fixed
batches. They are not counted as engine/runtime failures. All retained final
regression runs and the corrected comparison complete without watchdog expiry.

## Controlled comparison

`comparison.pl` loads either the committed pre-change adapter or the candidate
in a fresh process, on the same separate fixed engine. Its process-local
`library(prolog_wrap)` gate pauses just after the acquisition helper returns.
The old helper returns before deferred recording; the new helper returns after
recording. The parent injects `$abort_goal`, and the owner runs the exact
`down(unrelated,probe,killed)` timeout-zero assertion and inspects storage.

All 20 baseline cases report `failed(missing_unrelated,absent,absent)`; all 20
candidate cases report `ok`. These processes exit 0 because the diagnostic
reports outcomes; result counts, not process exits alone, establish the
comparison. The gate intentionally exposes a legal interruption point. It is
not a natural failure-rate estimate, and does not establish a new native SWI
engine defect.

## Reproduction and files

From the demonstrator root:

```sh
python3 docs/verification/swi-receive-handoff-2026-10-23/run.py
```

The script pins the separate executable at:

`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299/build/src/swipl`

It uses fresh processes and external process-group watchdogs for the tiers and
fixed repeated groups. `results.json`, `runner.log` and the named logs preserve
the initial batch. The corrected node result is stored separately. Repeated
groups run within one process per group; they are not 30/10 fresh-process trials.

`provenance.json` records the baseline repository commit, fixed-engine source
commit and binary hash, candidate source/test hashes and the installed engine
hashes. `controlled-comparison.json` records the before/after diagnostic.
To rerun that comparison, save the recorded baseline's actors.pl using `git show`
and pass each adapter path separately to:

```sh
/path/to/fixed/swipl -q -s docs/verification/swi-receive-handoff-2026-10-23/comparison.pl \
  -g 'receive_handoff_swi_gated:run,halt' -- /path/to/actors.pl
```

Permanent regression: `tests/tiers/receive_handoff_tests.pl`, included in T0.
Implementation/dependency notes: `prolog/web_prolog/README.md`.
The shared language manual, book examples, browser runtimes and installed
engines were not changed by this batch.
