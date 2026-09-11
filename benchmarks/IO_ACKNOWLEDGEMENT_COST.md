# Remote terminal I/O: acknowledgement cost

Scope: these measurements cover a native home-node terminal queue. The later
SWI-WASM fix extends acknowledgement to the browser across its peer connections;
the additional browser round trip is not measured by this benchmark.

The acknowledgement has a measurable cost, dominated by network latency for sequential small writes. Explicitly grouping bulk text into one acknowledged write recovers most of the throughput without weakening the completion guarantee. Keep acknowledgement as the default; do not add a silent owner-wide or user-wide override.

## Delivery time

Medians of three repetitions, one writer. The two delayed scenarios send 400 logical lines; the zero-added-delay scenario sends 2,000. Each line is 64 ASCII bytes, including its newline. Compare modes within a column, not raw times across columns. All columns use the same TCP proxy.

| Mode | 0 ms added RTT, 2,000 lines | 10 ms added RTT, 400 lines | 50 ms added RTT, 400 lines |
|---|---:|---:|---:|
| Asynchronous, one line/write | 0.604 s | 0.131 s | 0.180 s |
| Acknowledged, one line/write | 0.703 s | 5.237 s | 21.598 s |
| Acknowledged, 10 lines/write | 0.110 s | 0.527 s | 2.173 s |
| Acknowledged, 100 lines/write | 0.041 s | 0.055 s | 0.221 s |

At 50 ms added RTT, 100-line batches cut acknowledged delivery time from 21.6 seconds to 0.221 seconds (about 98×). Four independent writers reduce one-line acknowledged delivery to 5.388 seconds: writers can overlap their waits, but each writer still waits for its own reply.

The asynchronous sender returns before delivery. In the 50 ms case it returned after 9.9 ms, but completed delivery took 180 ms. The benchmark waits for a final acknowledgement on the same connection so it does not confuse local enqueueing with completed remote delivery. The ordinary async path provides no such per-write guarantee.

## CPU, traffic, and memory

The following CPU figures use the zero-added-delay scenario, one writer, 2,000 lines. They are process CPU time, not wall time; client and home-node figures include their existing transport, logging, and collector work. Proxy CPU is excluded. Wire bytes include WebSocket framing and application data, but exclude TCP/IP and TLS overhead. Handshake/warmup traffic is excluded; async includes its final measurement barrier.

| Mode | Client CPU | Home-node CPU | WebSocket bytes/logical line |
|---|---:|---:|---:|
| Asynchronous, one line/write | 39.4 ms | 607.4 ms | 173.2 |
| Acknowledged, one line/write | 162.1 ms | 726.5 ms | 381.0 |
| Acknowledged, 10 lines/write | 20.4 ms | 102.9 ms | 97.5 |
| Acknowledged, 100 lines/write | 5.6 ms | 35.1 ms | 69.2 |

In this low-latency scenario, individual acknowledgements add about 16% to delivery time and 37% to combined client/home CPU compared with the asynchronous baseline. The 64-byte payload is deliberately small, so protocol overhead is prominent: about 2.2× the wire traffic for individual acknowledged writes. Larger payloads amortize that overhead.

The memory probe holds the actual nonce, pending-request record, and empty reply-queue allocations live in fresh processes. It excludes actor threads and network connections. Median RSS increases were:

| Outstanding request allocations | Additional RSS | Threads before → after |
|---|---:|---:|
| 0 | 0.000 MiB | 2 → 2 |
| 1,000 | 1.328 MiB | 2 → 2 |
| 10,000 | 8.562 MiB | 2 → 2 |

This suggests roughly 1 KiB of retained allocation per outstanding request at scale, not an exact object-size measurement or hard bound. RSS includes allocator granularity, atom storage, and first-use overhead. Normal acknowledged operation has at most one pending request per blocked writer, and creates no additional thread per write. All 72 transport cases ended with zero pending requests.

## What batching means here

The benchmark prepares several logical lines and submits them as one terminal write. The existing API already supports this, for example:

```prolog
format('First line.~nSecond line.~nThird line.~n').
```

This is suitable for a report or a block of log text that is already available. It is not transparent buffering of separate calls: returning from an unacknowledged write, sending an actor message, and flushing later would reintroduce the ordering bug. It also changes the output chunk boundaries; consumers that need one event per record must account for that.

Example 09 cannot amortize its waits this way. Each receipt line belongs before the next ping/pong message. Its additional latency is the cost of preserving that causal relationship across a network.

An explicitly asynchronous logging interface could be useful if a workload requires immediate fire-and-forget records and accepts weaker ordering/delivery semantics. That should be a deliberate program-level choice, not an owner setting that silently changes ordinary `format/1-2` semantics. No runtime toggle or buffering API was added in this experiment.

## Method and reproduction

- Environment: macOS-26.5.1-arm64-arm-64bit; SWI-Prolog version 10.1.3 for fat-darwin.
- Separate native SWI client and home-node processes. The real authenticated `io_request`/`io_reply` transport is used. A terminal collector verifies message and character counts; browser rendering is excluded.
- The async baseline reproduces the successful pre-acknowledgement send behavior through a benchmark-only branch. Production hooks are not replaced.
- A FIFO TCP proxy adds 0, 5, or 25 ms of propagation delay in each direction. It does not serialize a full delay per packet; queued packets retain their own delivery deadlines. These are simulated delays, not measurements of the deployed nodes.
- Connections and payloads are warmed/prepared, and writer threads are created, before timing. One home node remains alive across the run; case order is shuffled with seed 42.
- 3 repetitions × 3 added RTTs × 2 writer counts × 4 output modes = 72 cases, plus 9 fresh-process memory probes.
- CPU values include existing node work. Host scheduling and proxy overhead add to the requested RTT (the 50 ms case had approximately 54 ms median per-write latency). Three repetitions support indicative comparisons, not precise tail-latency claims.

```sh
python3 benchmarks/run_io_ack_probe.py \
  --swipl /Applications/SWI-Prolog.app/Contents/MacOS/swipl
```

Use `--swipl` or the `SWIPL` environment variable on other installations. The runner uses Python’s standard library and writes results after each case; a full default run has 72 rows and 9 memory records.

- [Raw measurements](io_ack_probe_results.json)
- [Python runner and latency proxy](run_io_ack_probe.py)
- [Prolog probe](io_ack_probe.pl)
