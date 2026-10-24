# HTTP shutdown can swallow http_stop/1 inside the scheduling hook

`http_stop_server/2` can block indefinitely if its stop signal arrives while the acceptor is inside `http:schedule_workers/1`.

Tested on macOS arm64 with SWI core `09b6299f696574c9230f23e53b1ab041a942b6f3` (reports 10.1.18) and HTTP package `9d1e28e676831618c9894f728ef50872b2eb87d7`. No claim is made here about later upstream commits.

In `thread_httpd.pl`, `http_enough_workers/3` handles scheduling-hook exceptions with:

```prolog
catch(http:schedule_workers(Data), Error, print_message(error, Error))
```

Shutdown sends `throw(http_stop(Stopper))` to the acceptor. If delivered inside this catch, it is printed and consumed. The acceptor returns to `tcp_accept/3`, while the shutdown caller waits in `thread_join/2`. The shutdown routine's fallback connection wakes the acceptor but cannot restore the swallowed exception. The outer accept loop already rethrows `http_stop(_)` through `accept_rethrow_error/1`; the inner scheduling catch prevents that handler from seeing it.

This was observed naturally in a Web Prolog callback-sandbox test after the expected error response had already reached its client. A standalone example using only SWI HTTP/socket libraries reproduces the same interleaving by gating the public scheduling hook while initiating shutdown. The unpatched process prints:

```text
ERROR: [Thread http@...] Unknown message: http_stop(main)
```

and remains blocked until the external 30-second watchdog ends it. Native samples show the caller in `thread_join` and the acceptor in `accept`.

The attached candidate patch reuses `accept_rethrow_error/1` in the scheduling catch. Ordinary scheduling errors continue to be reported and recovered from. It adds `test_thread_httpd.pl` and registers it with the HTTP package's `test_libs` list. The three regression cases cover shutdown during the scheduling hook, recovery from an ordinary hook exception, and normal idle shutdown.

Apply at the HTTP package root:

```sh
patch -p1 < http-shutdown.patch
swipl -f none -q -s test_thread_httpd.pl -g test_thread_httpd -t halt
```

Use an external process watchdog when running the shutdown regression on unpatched libraries, because the bug itself blocks cleanup. The regression has five-second message waits; acceptance runs used a 30-second outer process watchdog.

Verification with the candidate library in a separate complete runtime prefix:

- New regression suite: 20/20 fresh processes, all three cases passing each time.
- Original callback-sandbox test: 30/30 fresh processes pass, unchanged assertions and timeouts.
- Native paging plus HTTP continuation eviction/TTL/isolation cleanup checks: 5/5 batches pass.
- Complete native T4 suite: all 983 scheduled cases pass.
- Existing HTTP, CGI-stream, multipart, proxy, WebSocket, GraphQL and SSE test entry points pass. The first proxy attempt lacked the source-tree certificate fixtures; after those fixtures were copied into the separate test tree, all 13 proxy cases passed. That initial setup failure is retained in the verification record.

No C changes or engine rebuild were needed: the candidate is a private copy of the complete staged installation with only the Prolog HTTP source changed. Existing installed runtimes and running application nodes were not modified. Submitted with the standalone reproducer and complete patch as https://github.com/SWI-Prolog/packages-http/issues/176.
