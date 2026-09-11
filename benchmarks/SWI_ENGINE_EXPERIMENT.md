# First SWI engine experiment

Date: 2026-09-11. Runtime: SWI-Prolog 10.1.3, macOS 26.5.1,
Apple Silicon. Raw observations: [swi_engine_probe_results.json](swi_engine_probe_results.json).

The demonstrator's layer-0 actor core uses one SWI thread per actor.
This experiment establishes a memory baseline and checks the scheduling
consequence of replacing threads with engines on a single worker. It does
not implement a replacement actor runtime or change demonstrator semantics.

## Reproduce

From the repository root:

```sh
python3 benchmarks/run_swi_engine_probe.py \
  --swipl /Applications/SWI-Prolog.app/Contents/MacOS/swipl \
  > benchmarks/swi_engine_probe_results.json
```

On other installations, omit `--swipl` to use `SWIPL` or `swipl` on PATH.
The driver requires Python 3, SWI-Prolog and permission to execute `ps`.
It runs three repetitions at populations 0, 10, 100 and 250, with every
measurement in a fresh process. Each child has a 30-second timeout at
each protocol wait and at shutdown. Smaller smoke run:

```sh
python3 benchmarks/run_swi_engine_probe.py --counts 0 10 \
  --repetitions 1 --iterations 100000
```

## Memory results

Median additional resident memory divided by the population, in KiB:

| Substrate | 10 instances | 100 instances | 250 instances |
|---|---:|---:|---:|
| Raw SWI thread | 76.8 | 77.9 | 77.9 |
| Demonstrator layer-0 actor | 89.6 | 84.8 | 82.4 |
| Suspended SWI engine | 62.4 | 61.6 | 61.6 |

At 250 instances the engine figure is about 25% below the actor figure.
It is still roughly 60 MiB per thousand engines if this slope continues;
that extrapolation is not a measurement at a thousand engines.

The driver reads RSS before creating the population and again after all
instances report readiness. Threads then wait on their mailboxes, actors
wait in the existing `receive/1`, and engines suspend at `engine_yield/1`.
All subprocesses load the same harness and actor module. The zero-population
control records measurement noise; it is not subtracted from other rows.

The engines have no actor registry, selective-receive mailbox, monitor/link
implementation, or isolated module. Their result is a substrate baseline,
not an equivalent actor implementation. The actor run uses the standalone
core, not the full node's isolation and policy layers. RSS includes resident
allocator pages and harness overhead, excludes uncommitted virtual memory,
and is neither a precise object size nor a worst-case memory requirement.
These measurements use default allocation policies and almost empty states.

## Scheduling results

Both engine computations first yield readiness. The harness then dispatches
a busy engine for 5,000,000 tail-recursive countdown steps before dispatching
the ready probe engine, on the same worker thread. The countdown contains
no explicit yield. Probe delay therefore includes the first dispatch.

For the actor comparison, a busy actor announces that it is starting the
same countdown. The controller then sends a ping to a separate actor and
times the pong. Actor creation is outside the timed interval; the harness
also waits for the countdown to finish before cleanup.

| Substrate | Median probe delay | Range, three runs |
|---|---:|---:|
| Threaded actors | 0.010 ms | 0.010–0.012 ms |
| Engines, one worker | 42.825 ms | 37.241–49.913 ms |

This demonstrates head-of-line blocking in this direct engine dispatch
scheme. It is not a throughput comparison, a latency guarantee, or evidence
that every possible SWI engine scheduler must behave this way. The actor
case can use other CPU cores; no CPU affinity is imposed. Neither test
covers long foreign calls, garbage collection pauses or large unifications.
Timing uses wall-clock `get_time/1`; short measurements are illustrative.

The documented engine interface starts or resumes a computation through
[`engine_next/2`](https://www.swi-prolog.org/pldoc/man?predicate=engine_next/2),
and allows that computation to suspend through
[`engine_yield/1`](https://www.swi-prolog.org/pldoc/man?predicate=engine_yield/1).
A scheduler that merely cycles through `engine_next/2` calls has no execution
budget in this interface. Putting a fixed number of these workers in a pool
would still permit that many non-yielding computations to occupy the pool.

## Consequence for the next implementation

SWI engines are worth investigating, but replacing `thread_create/3` alone
would not deliver either tiny actors or fair scheduling. Two separate
questions now have concrete baselines:

1. How much of the approximately 62 KiB engine footprint can be reduced by
   allocation policy without changing SWI's execution semantics?
2. Can a running engine be suspended and resumed after an execution budget
   while preserving choice points, bindings, cleanup handlers and exceptions?

A cooperative actor adapter can first reuse the demonstrator's receive
selection rules while yielding when no matching message exists. Its tests
must retain the T0 cases for nonground messages, failed-guard rollback,
mailbox order, receive commitment, body alternatives, timeouts and lifecycle.
Passing those cases would still leave preemption as a separate requirement.
Terminating a goal with a time/inference limit is not a resumable timeslice.

Validation for this initial experiment: smoke run, 36 fresh-process memory
measurements, six scheduling measurements, and the existing T0 suite
(68 tests passed; its pre-existing singleton-variable warning remains).
No production runtime files were modified.
