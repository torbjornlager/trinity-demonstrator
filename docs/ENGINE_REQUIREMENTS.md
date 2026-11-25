# What Trealla and ECLiPSe would need for smooth ACTOR nodes

25 November 2026. This document is a list of engine features and libraries. If
the Trealla and ECLiPSe maintainers provided them, a conforming Web Prolog
ACTOR node could be written mostly in portable Prolog. It would need no
adapters and few workarounds.

The evidence comes from the two ports that run today:

- **trealla-port** runs N5. It is native, but it carries large workaround
  layers. See its `UPSTREAM_OUTSTANDING.md` and `UPSTREAM_REPORTS.md`.
- **eclipse-node** runs N7. A Python adapter of about 2,500 lines is its
  network stack and its sandbox. Every visitor gets an ECLiPSe engine in its
  own container with no network.

Node-to-node rules (pid forms, peer trust, delivery on close) are a matter for
the protocol, not the engines. See [DISTRIBUTION_AGENDA.md](DISTRIBUTION_AGENDA.md).

Priorities:

- **A** blocks a native, safely public node.
- **B** removes a large port layer or an operational risk.
- **C** is a convenience.

## Part 1: what an ACTOR node needs from any engine

| # | Need | Why the ACTOR profile needs it | Pri |
|---|---|---|---|
| 1 | **Processes with their own mailbox.** Native threads, or engines that run in threads. Each needs a message queue with a selective, blocking receive, a relative timeout and an absolute deadline. | Every actor, toplevel and connection is one process, and `receive/1,2` maps directly onto this. | A |
| 2 | **Asynchronous interrupts.** Any process, including one blocked on a queue, socket read or `accept`, can be made to run a goal or throw. Cleanup handlers (`setup_call_cleanup/3`, `at_exit`) must run, and an interrupt must never reach a different thread that reused the same id. | `exit/2`, `toplevel_abort`, kill-on-close and timeouts. | A |
| 3 | **A safe thread lifecycle.** Exit status, `at_exit` hooks, detach and join that do not race with cleanup, and stable behaviour with thousands of short-lived threads. | Monitors and `down` messages, and the long-running public nodes. | A |
| 4 | **Cheap, isolated namespaces per actor.** Create a module, load source text into it, run in it and destroy it. That must be thread-safe, and destroying a module must actually free its memory. | `src_text/1`, `src_list/1`, `src_predicates/1` and `src_uri/1`, with private code per actor. | A |
| 5 | **A sandbox.** A static safe-goal checker for a configurable set of allowed built-ins, like SWI's `library(sandbox)`, or a restricted execution mode with no files, OS, network or `halt`. | Public nodes run code from strangers. Without a sandbox, isolation needs one container per visitor. | A |
| 6 | **Resource limits per process.** Inference or CPU budgets, wall time, and memory quotas on heap, stack and trail. Exceeding one raises `resource_error(_)` in that process only. | One visitor must not kill the node. N5 was killed at its container's memory limit on 24 November. | A |
| 7 | **Network libraries.** An HTTP/1.1 server with keep-alive and the ability to hand an upgraded socket to a WebSocket. An RFC 6455 WebSocket server and client. An HTTPS client with SNI and certificate checks, and ideally a TLS server. Timeouts must be enforced on connect, read and write, and closing a listener must wake its `accept`. | The node's HTTP API and WebSocket endpoint, and outbound `rpc/3`, remote spawns, sends and monitors, and `src_uri`. | A |
| 8 | **Data formats and cryptography.** JSON read and write with exact Unicode semantics (surrogate pairs, lone surrogates rejected), URL encoding, base64, SHA-1 (for the WebSocket handshake), SHA-256 and HMAC, constant-time compare, and secure random bytes. | The WebSocket protocol's JSON frames, the handshake, tokens and session ids. | A |
| 9 | **Faithful term text.** `read_term/2` and `write_term/2` with `variable_names`, `quoted(true)`, `ignore_ops` and standard operators. Atoms and strings count Unicode code points. `double_quotes` behaves as in ISO and SWI. Copying, sending, `nb_setval` and `catch/3` either preserve cyclic terms or reject them. | Terms travel between nodes as text and must read back identically on SWI, Trealla and ECLiPSe. | A |
| 10 | **ISO error terms everywhere.** Built-ins throw `error(Formal, Context)` with ISO formals, not engine event numbers. | Exceptions cross nodes and are compared by the conformance suite. | A |
| 11 | **Suspendable solution streams.** Engines (`engine_create/3`, `engine_next/2`, `engine_destroy/1`) or an equivalent. A query yields one or N answers, waits, and is resumed later from another request or thread. | Toplevel paging (`toplevel_next`), `offset`/`limit` in `/call`, and `findnsols`-style chunks. | A |
| 12 | **Long-run memory stability.** Atom and clause garbage collection for servers that create and destroy modules, threads and atoms all day. Retained clauses must not wait for queries that never end. | Today's N5 leak, which needed an engine patch. | B |
| 13 | **Meta-predicate declarations that qualify any `:` argument** (lists and other containers too), and `call/N`. | Supervisor child specifications and callbacks inside lists. | B |
| 14 | **An XML parser** compatible with SWI's `load_structure/3` (`element(Name, Attributes, Children)`, `space(remove)`), ideally with DTD validation. | SXML statecharts. Both ports carry a 500-line parser. | B |
| 15 | **Typed application settings** (`library(settings)`) and a PlUnit-compatible test framework. | Node configuration, and sharing tests with SWI. | C |

## Part 2: Trealla

Trealla already serves the protocol natively. What is left is mostly
robustness, plus libraries that move code out of the port.

Already fixed upstream for the port:

- issues #1172–#1178: read timeouts, thread status retirement, module creation
  in threads, module-table races, idempotent imports;
- absolute deadlines for `thread_get_message/3`;
- independent concurrent sleeps;
- `library(sandbox)`, `library(debug)` and `number_of_clauses`.

| # | Request | Evidence in the port | Pri |
|---|---|---|---|
| T1 | **Free a destroyed temporary module's clauses once the queries that used it end**, not when every live query ends. | The N5 leak of 24–25 November. Fixed by a local patch on `841f819` (branch `scoped-module-reclaim`, `da55c99`), live on N5 but not yet offered upstream. | A |
| T2 | **Per-thread memory quotas** that raise `resource_error` in the offending thread. | N5 was killed by the container limit. The port can limit stack size and inferences, but not a thread's heap. | A |
| T3 | **`thread_cancel/1` and `thread_signal/2` wake a thread blocked in `thread_get_message`, socket read or `accept`, and run its Prolog cleanup.** | An unfiled observation: a cancelled queue reader keeps running until a message arrives, and its cleanup is skipped. `node.pl` keeps a wake-up connection so a listener can be closed. | A |
| T4 | **Signals never reach a thread that has reused a retired thread's storage.** | `native_thread_control.pl` rechecks the id in the receiver. | A |
| T5 | **Cleanup runs when a thread ends with an open choice point.** | Found on 24 November. Two `setup_call_cleanup` goals now need `once/1` in `node.pl` and `node_settings.pl`. | A |
| T6 | **Cyclic terms survive** copying, `nb_setval`, thread hand-off and `catch/3`, or are consistently rejected. | `answer_terms.pl`: on v3.14.10 such terms come back as acyclic approximations. | B |
| T7 | **A native WebSocket library**, client and server with `wss`, following SWI's message terms, and an HTTP server library with a socket hand-off for upgrades. | The port's own `websocket.pl` (845 lines) and the HTTP server in `node.pl`. | B |
| T8 | **One JSON contract for surrogates** across versions. | `json_wire.pl` normalises older and newer bundled grammars. | B |
| T9 | **A `:` meta-argument qualifies lists** (BUG-022, ready to send). | Supervisor child lists are passed as `Module:Specs` by hand. | B |
| T10 | **Terms built with `functor/3` are callable and evaluable** (BUG-023; retest first). | The port uses `=../2` instead. | B |
| T11 | **Thread safety** under concurrent remote startup. | Intermittent `match_head` crashes in `start_routine_thread_create`, not yet reduced to a reproducer. | B |
| T12 | **An XML parser** like SWI's `library(sgml)` subset. | `sxml_parser.pl`, 513 lines. | B |
| T13 | **`library(settings)` and a PlUnit-compatible test framework.** | `node_settings.pl`, and a home-grown test runner. | C |

With T1–T5 and T7, a Trealla node would need no workaround code beyond the
Web Prolog library itself.

## Part 3: ECLiPSe

ECLiPSe's engines-in-threads, records and stores are a good base for actors.
But N7 can be public only by keeping the engine off the network and putting one
container around each visitor. So the largest wins are a sandbox, resource
limits and networking. The Python adapter's protocol logic would then move into
Prolog.

| # | Request | Evidence in N7 | Pri |
|---|---|---|---|
| E1 | **A sandbox inside the engine.** A safe-goal checker, or a restricted module or engine mode with no file, OS, network, `halt` or debugger access. | Today: one Docker container per visitor, no network, at most four engines on the node and two per client. | A |
| E2 | **Resource limits per engine** for memory, CPU or inferences, and wall time, raising an error in that engine only. | Today the container sets CPU, memory and task limits. | A |
| E3 | **Network libraries:** HTTP/1.1 server and client, WebSocket server and client, TLS client with certificate checks (ideally a server too), and enforced timeouts. | `isotope_http.py` and `n7_actor_ws.py`, about 2,500 lines of Python, pass JSON to the engine over stdin and stdout. Outbound requests go through the adapter's allowlist. | A |
| E4 | **ISO error terms by default.** | `start_actor_runtime` installs handlers for events 21, 85 and 86, and the runtime maps errors to ISO and SWI formals by hand (`n7-language-alignment.md`). | A |
| E5 | **ISO and SWI syntax compatibility as a complete, supported mode:** doubled quotes, `double_quotes`, standard operators and `0'c`. | `syntax_option(doubled_quote_is_quote)` in every module, plus `library(swi)`. | A |
| E6 | **Unicode code-point semantics** for `atom_length/2`, `sub_atom/5`, `atom_codes/2`, `atom_concat/3` and string built-ins. | `web_prolog_library.ecl` rebuilds them on `atom_chars/2`, because the native ones count UTF-8 bytes. | A |
| E7 | **ISO arithmetic:** evaluation errors instead of infinity for zero divisors, and left-to-right operand evaluation. | `portable_arithmetic.ecl`. | B |
| E8 | **Thread message queues** with a blocking selective receive, timeout and deadline, interruptible as in Part 1, item 2. | Mailboxes are built from records and bags. Waits are bounded "so the toplevel can deliver Abort". | A |
| E9 | **Predictable timing of interrupts and cleanup.** A cleanup event finishes before the interrupted goal's caller continues. | `actors.ecl` notes that "ECLiPSe's cleanup event can run after this predicate returns", so events are deferred around critical sections. | B |
| E10 | **`meta_predicate` and `call/N` as an alternative to `tool/2`** for portable library code. | Every exported meta predicate is declared twice (`tool(spawn/2, spawn_/3)`). | B |
| E11 | **Cryptography and encodings:** secure random bytes, SHA-1, SHA-256, HMAC and base64. | Needed once the network is native, for the WebSocket handshake, tokens and sessions. They live in Python today. | B |
| E12 | **Destroying a module frees its memory** in a long-running engine, with thread-safe module creation. | Not tested yet on N7, because engines are disposable. It becomes item A once one engine serves many visitors. | B |
| E13 | **An XML parser** like SWI's `library(sgml)` subset. | `sxml_document.ecl`, 563 lines. | B |

With E1–E3, an ECLiPSe node could run all visitors in one engine process behind
an ordinary TLS edge, like SWI and Trealla. With E4–E8, the compatibility
modules shrink to the Web Prolog library itself.

## Suggested order of conversation

1. **Trealla:**
   - offer the T1 patch upstream (publishing it is the owner's decision);
   - file BUG-022, plus BUG-023 after a retest;
   - discuss T2 and T3, which are design questions rather than bugs.
2. **ECLiPSe:** E1–E3 are architectural questions. Start by asking whether a
   restricted engine mode (E1) and engine resource limits (E2) fit ECLiPSe's
   plans. Networking (E3) can then come from a library, even a foreign one.
3. **Both:** item 9 (term text) and item 10 (ISO errors) decide whether answers
   read back identically across nodes. A shared set of read and write test
   vectors from the conformance suite would help both maintainers.
