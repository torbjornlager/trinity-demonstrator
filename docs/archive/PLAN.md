# ACTOR Profile Implementation Plan

This document is archived. It is kept for historical context and should not be read as the current implementation plan.


This document is archived. It is kept for historical context and should not be read as the current implementation plan.


## Overview

Add the ACTOR profile — the third layer of the Web Prolog architecture — to the PoC.
This gives browser clients full actor capabilities via WebSocket:

- A browser connects via WebSocket to `/ws`
- It can spawn toplevel actors (query engines) and bare actors on the server
- Actor messages (success, failure, error, output, prompt, down, ...) are relayed
  back over the WebSocket as JSON events
- The browser can send arbitrary messages to any server-side actor

## Architecture

```
Browser (JS)
  │
  │ WebSocket (JSON frames)
  │
  ▼
/ws endpoint ──► http_upgrade_to_websocket
                     │
                     ├── WS Reader Thread
                     │     reads JSON commands from browser,
                     │     dispatches to ws_action_* handlers
                     │
                     ├── WS Relay Thread
                     │     reads from per-connection Queue,
                     │     serializes events to JSON via answer_to_json/2,
                     │     sends over WebSocket with ws_send/2
                     │
                     └── Per-connection Queue
                           ▲
                           │ actor messages
                           │
                     Toplevel Actors / Bare Actors
                       (target = Queue)
```

Key insight: `ws_send/2` in SWI-Prolog is thread-safe — but routing all
outbound messages through a single relay thread is cleaner and avoids
interleaving partial frames.

## WebSocket Protocol (JSON)

### Commands (browser → server)

| command           | fields                                 | description                    |
|-------------------|----------------------------------------|--------------------------------|
| toplevel_spawn    | options? (string)                      | spawn a toplevel actor         |
| toplevel_call     | pid, goal, template?, limit?, once?,   | submit a query                 |
|                   | load_text?                             |                                |
| toplevel_next     | pid, limit?                            | request next solutions         |
| toplevel_stop     | pid                                    | stop paging                    |
| toplevel_abort    | pid                                    | abort current query            |
| toplevel_respond  | pid, input                             | respond to a prompt            |
| spawn             | goal, options?                         | spawn a bare actor             |
| send              | pid, message                           | send message to any actor      |

### Events (server → browser)

Reuses the existing `answer_to_json/2` vocabulary from `node_response.pl`:

| type      | fields                | when                           |
|-----------|-----------------------|--------------------------------|
| spawned   | pid                   | actor created                  |
| success   | pid, data, more       | query solutions                |
| failure   | pid                   | query failed (no solutions)    |
| error     | pid, data             | exception during query         |
| output    | pid, data             | actor called output/1          |
| prompt    | pid, data             | actor called input/2           |
| timeout   | pid                   | query timed out                |
| stop      | pid                   | paging stopped                 |
| abort     | pid                   | computation aborted            |
| down      | pid, reason           | actor terminated               |

## Files to Create

### 1. `node_ws.pl` — WebSocket handler module (~180 lines)

New module with:

- `:- http_handler(root(ws), ws_handler, [spawn([]), id(ws)]).`
- `ws_handler/1` — upgrade HTTP to WebSocket, start reader + relay threads
- State: `ws_connection/3` — dynamic `ws_connection(Socket, Queue, RelayThread)`
- State: `ws_toplevel/2` — dynamic `ws_toplevel(Socket, Pid)` to track cleanup
- `ws_read_loop/2` — receive JSON, dispatch, loop; on close → cleanup
- `ws_relay_loop/2` — read queue → `answer_to_json` → `ws_send(json(...))`
- `ws_dispatch/4` — match command atom, call ws_action_*
- `ws_action_toplevel_spawn/3` — spawn via `toplevel_spawn/2`, target=Queue
- `ws_action_toplevel_call/3` — parse goal, send `$call` to toplevel
  - Reuses `rewrite_isotope_goal/2` and `load_text_into_session/2`
- `ws_action_toplevel_next/3` — send `$next(Options)` to toplevel
- `ws_action_toplevel_stop/3` — send `$stop` to toplevel
- `ws_action_toplevel_abort/3` — signal abort via `toplevel_abort/1`
- `ws_action_toplevel_respond/3` — send `$input` to toplevel
- `ws_action_spawn/3` — `spawn/3` a bare actor with monitor
- `ws_action_send/3` — `send/2` message to any pid
- `ws_cleanup/1` — on close: kill relay thread, destroy queue, exit toplevels

### 2. Modifications

#### `node.pl`
- Add `:- use_module(node_ws).` — this triggers the http_handler registration
- Add "Actor (WebSocket)" option to the shell API mode selector

#### `node_response.pl`
- Export `answer_to_json/2` (currently internal)
- Add clause for `down(Pid, Reason)` events

#### `shell.html`
- Add third `<option>` in API mode dropdown: "Actor (WebSocket)"
- Add WebSocket connection management:
  - `wsConnect()` — open WebSocket to `ws://<host>/ws`
  - `wsSend(command)` — send JSON command
  - `ws.onmessage` — dispatch events to `handleWsEvent()`
  - `ws.onclose` / `ws.onerror` — reconnection / error display
- `handleWsEvent()` — reuses existing `handleIsotopeEvent()` display logic
  for success/failure/error/output/prompt/timeout/abort
- `askCurrentWs()` — spawn-if-needed, then send toplevel_call
- `nextSliceWs()` — send toplevel_next
- `stopPagingWs()` — send toplevel_stop
- `respondToPromptWs()` — send toplevel_respond
- `abortWs()` — send toplevel_abort

## Execution Order

1. Export `answer_to_json/2` from `node_response.pl`, add `down/2` clause
2. Create `node_ws.pl` with full WebSocket handler
3. Wire `node_ws` into `node.pl`
4. Update `shell.html` with WebSocket API mode
5. Test manually via the shell
6. Run existing test suite to verify no regressions
