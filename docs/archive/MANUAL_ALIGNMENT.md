# Draft Manual Alignment Notes

This document is archived. It is kept for historical context and has been superseded by a newer consolidated note.


This note compares the draft manual excerpt with the current implementation in
this repository.

It has two goals:

- identify where the draft still matches the code
- identify where the implementation has moved on and the draft should change

The second half gives a proposed replacement excerpt written against the code
as it exists now.

## What Still Resonates

The draft is still broadly right about the shape of the system.

- The repository is actor-first. [`actor.pl`](actor.pl)
  is the foundation, and the higher-level pieces are built on top of it.
- The actor API in the draft mostly matches the exported predicates in
  [`actor.pl`](actor.pl).
- The toplevel actor story is still accurate:
  [`toplevel_actor.pl`](toplevel_actor.pl)
  is a query engine actor that speaks a small mailbox protocol and returns
  `success`, `failure`, and `error` messages.
- The supervisor section matches
  [`supervisor_actor.pl`](supervisor_actor.pl)
  well, including child specs, restart policies, and synchronous query calls.
- The statechart section matches
  [`statechart_actor.pl`](statechart_actor.pl)
  well: one source option is required, `load_list/1` and
  `load_predicates/1` are rejected, and `raise/1` exists as a statechart
  builtin.
- The RPC section also resonates conceptually:
  [`node_client.pl`](node_client.pl)
  really does treat `rpc/3` as nondeterministic remote execution over `/call`.

In short, the model in the draft is still the right model. The drift is mostly
in distribution, pid semantics, node surface area, and some exact protocol
details.

## Where the Draft Is Out of Date

### 1. Remote `node(+URI)` support is now implemented

The draft still describes distributed `node(+URI)` as mostly a vision-level
feature for `spawn/3`.

That is no longer true.

- [`actor.pl`](actor.pl)
  supports remote actor spawning over WebSocket.
- [`toplevel_actor.pl`](toplevel_actor.pl)
  supports remote toplevel spawning and remote paging through local proxy
  actors.
- [`node_ws.pl`](node_ws.pl)
  implements the server side of that ACTOR-profile transport.

The draft should stop saying that non-local `node/1` values are unimplemented.

### 2. The pid model is now global

The draft largely talks as if pids are plain integers.

The current implementation has moved toward canonical global pids of the form
`Id@Node`.

- [`actor.pl`](actor.pl)
  normalizes pid values with `canonical_pid/2`.
- [`node.pl`](node.pl)
  and [`node_session.pl`](node_session.pl)
  accept both integer pid forms and canonical `Id@Node` forms for session
  endpoints and bookkeeping.

One nuance: JSON still returns plain integers for local pids in some places for
backward compatibility. The runtime model is nevertheless global.

### 3. `link(true)` is directional, not symmetric

The draft wording for `link(true)` is too Erlang-like.

The current implementation uses directional parent-to-child cleanup, not
symmetric bidirectional links.

What `link(true)` means in the code is:

- when a parent spawns a child with linking enabled, the parent records a
  link to that child
- if the parent exits, the linked child is killed
- if the child exits, the parent is not killed just because of that link

That behaviour comes from the link bookkeeping and cleanup logic in
[`actor.pl`](actor.pl).

### 4. Shared DB clauses are imported, not injected into each actor

The draft's wording around actor source loading is mostly right, but it should
distinguish actor-private source from node-shared source.

The current node implementation loads shared DB source once into a dedicated
runtime module and imports that module into actor modules.

- [`node.pl`](node.pl)
  loads the shared DB runtime module.
- [`actor.pl`](actor.pl)
  imports that module when preparing an actor.

So shared DB clauses are not copied into every actor's private database.

### 5. `send/2` is more pid-centric than the draft suggests

The draft says `PidOrName` must have the form `Pid@Node` or `Name@Node`, with
local abbreviations.

That is not how the implementation is best described.

The current code clearly supports:

- local plain pids
- local plain registered names
- global pids of the form `Id@Node`

Global name forms are not normalized as consistently as global pid forms, so
the manual should not over-promise there.

### 6. The node now exposes more than `/call`

The draft node deployment section still says `node/1` exposes `/call` and that
additional endpoints appear only if extra modules are loaded beforehand.

That is outdated for this repository.

[`node.pl`](node.pl) now exposes:

- `/`
- `/call`
- `/toplevel_spawn`
- `/toplevel_call`
- `/toplevel_next`
- `/toplevel_poll`
- `/toplevel_stop`
- `/toplevel_abort`
- `/toplevel_respond`
- `/shell`
- `/ws` via [`node_ws.pl`](node_ws.pl)

### 7. The documented node timeout default is wrong

The draft says `node:timeout` defaults to `100`.

The current code sets:

- `node:cache_size = 100`
- `node:timeout = 2`

See [`node.pl`](node.pl).

### 8. The semi-stateful HTTP endpoint responses are partly stale

The draft's HTTP tables and endpoint descriptions are behind the code.

Current behaviour:

- `/toplevel_spawn` returns `spawned` or `error`
- `/toplevel_call`, `/toplevel_next`, and `/toplevel_poll` can return
  `success`, `failure`, `error`, `output`, `prompt`, `timeout`, or `abort`
- `/toplevel_respond` returns `responded`, not the final next protocol event
- `/toplevel_stop` returns `stop`
- `/toplevel_abort` returns `abort`

These are defined by the controller/session flow in
[`node.pl`](node.pl),
[`node_isotope_controller.pl`](node_isotope_controller.pl),
[`node_session.pl`](node_session.pl),
and [`node_response.pl`](node_response.pl).

### 9. HTTP ISOTOPE sessions are always sessions

The draft table for `/toplevel_spawn` still describes `session` as if it were a
real external toggle with default `false`.

In the actual HTTP ISOTOPE API, `session(true)` is forced by
[`node_isotope_options.pl`](node_isotope_options.pl).

That option still matters for the underlying actor API, but not for the HTTP
ISOTOPE endpoint in the way the draft currently suggests.

### 10. `promise/4` documents more options than the code currently supports

The draft gives `promise/4` a richer API than is implemented.

In the current code, [`node_client.pl`](node_client.pl)
supports:

- `template/1`
- `offset/1`
- `limit/1`

It does not currently implement the richer `once/1`, timeout, or source-loading
story that the `rpc/3` path has.

### 11. The WebSocket API is no longer a TODO

The draft still leaves the stateful WebSocket API section empty.

That is now one of the major implemented pieces:
[`node_ws.pl`](node_ws.pl).

The manual should now document the ACTOR WebSocket API as a first-class part of
the system.

## Proposed Current Manual Excerpt

This replacement text is written against the current implementation in this
repository. It is intentionally plain Markdown rather than LaTeX.

### Predicates for Programming with Actors

#### `self/1`

```prolog
self(-Pid) is det.
```

Binds `Pid` to the process identifier of the calling process.

The runtime uses a global pid model. Conceptually, pids are of the form
`Id@Node`, although local compatibility paths may still expose plain integers in
some contexts.

#### `spawn/1-3`

```prolog
spawn(+Goal) is det.
spawn(+Goal, -Pid) is det.
spawn(+Goal, -Pid, +Options) is det.
```

Creates a new actor process running `Goal`.

Supported options:

- `node(+URIOrLocalhost)`
  Runs the actor locally or on a remote compatible node. Default is
  `localhost`.
- `monitor(+Boolean)`
  If `true`, installs monitoring during spawn. Default is `false`.
- `link(+Boolean)`
  If `true`, installs directional parent-to-child link cleanup. Default is
  `true`.
- `load_text(+AtomOrString)`
  Loads source text into the actor's private module before running `Goal`.
- `load_list(+ListOfClauses)`
  Converts the clauses to source text and loads them into the actor's private
  module.
- `load_uri(+URI)`
  Loads source text from a file path, file URI, or HTTP(S) URI into the
  actor's private module.
- `load_predicates(+ListOfPredicateIndicators)`
  Serializes listed local predicates and loads them into the actor's private
  module.

Notes:

- `monitor(true)` during `spawn/3` is safer than calling `monitor/2` later for
  short-lived children.
- In the spawn-installed monitor case, the implementation uses `Ref = Pid`.
- Multiple `load_*` options may be given, including repeated variants. They are
  normalized to source text and loaded in option-list order.

#### `monitor/2`

```prolog
monitor(+PidOrName, -Ref) is det.
```

Installs a monitor on a pid or registered local name and returns a fresh
reference. When the monitored process terminates, the monitoring process
receives:

```prolog
down(Ref, Pid, Reason)
```

#### `demonitor/1-2`

```prolog
demonitor(+Ref) is det.
demonitor(+Ref, +Options) is det.
```

Stops monitoring identified by `Ref`. This is idempotent.

Supported option:

- `flush`
  Removes one pending `down(Ref, _, _)` message from the mailbox, if present.

#### `register/2`, `whereis/2`, `unregister/1`

```prolog
register(+Name, +Pid) is det.
whereis(+Name, ?Pid) is det.
unregister(+Name) is det.
```

Registers a local actor under a local atom name, looks up a name, or removes
the association. The name association is automatically removed when the process
terminates.

`whereis/2` binds `Pid` to `undefined` when no such process exists.

#### `exit/1-2`

```prolog
exit(+Reason) is det.
exit(+Pid, +Reason) is det.
```

`exit/1` terminates the calling process with `Reason`.

`exit/2` terminates the process identified by `Pid`. For remote actors, the
runtime routes this through the remote node.

#### `!/2`, `send/2-3`, `cancel/1`

```prolog
+PidOrName ! +Message is det.
send(+PidOrName, +Message) is det.
send(+PidOrName, +Message, +Options) is det.
cancel(+ID) is det.
```

Sends `Message` asynchronously to a local pid, a local registered name, or a
global pid of the form `Id@Node`.

Supported `send/3` options:

- `delay(+Number)`
  Delay sending by the specified number of seconds.
- `id(+ID)`
  Associates the delayed send with a user-supplied identifier that may later be
  passed to `cancel/1`.

`cancel/1` attempts to cancel all delayed sends with the given identifier.
Cancellation is best-effort only.

#### `output/1-2`, `input/2-3`, `respond/2`

```prolog
output(+Data) is det.
output(+Data, +Options) is det.

input(+Prompt, -Data) is det.
input(+Prompt, -Data, +Options) is det.

respond(+Pid, +Input) is det.
```

`output/1-2` sends:

```prolog
output(Pid, Data)
```

to a target process. By default the target is the parent process, but it may be
overridden with:

- `target(+Pid)`

`input/2-3` sends:

```prolog
prompt(Pid, Prompt)
```

to a target process and then waits for a response sent with `respond/2`.

`respond/2` delivers the input term back to the waiting actor.

#### `receive/1-2`

```prolog
receive(+Clauses) is semidet.
receive(+Clauses, +Options) is semidet.
```

Performs selective receive over the actor mailbox. Deferred messages stay in
the mailbox, in order.

Supported options:

- `timeout(+Number)`
  Wait at most the given number of seconds.
- `on_timeout(+Goal)`
  Goal to run when the timeout occurs.

### Predicates for Programming with Toplevel Actors

#### `toplevel_spawn/1-2`

```prolog
toplevel_spawn(-Pid) is det.
toplevel_spawn(-Pid, +Options) is det.
```

Spawns a toplevel query actor.

All ordinary `spawn/3` options may be used. Two additional options are:

- `session(+Boolean)`
  If `false`, the toplevel terminates after a single goal is run to completion.
  If `true`, it remains available for further interaction. Default is `false`
  in the actor API.
- `target(+PidOrQueue)`
  Send answer terms to this target. Default is the parent.

#### `toplevel_call/2-3`

```prolog
toplevel_call(+Pid, +Goal) is det.
toplevel_call(+Pid, +Goal, +Options) is det.
```

Submits `Goal` to the toplevel actor.

Supported options:

- `template(+Template)`
- `offset(+Integer)`
- `limit(+Integer)`
- `once(+Boolean)`
- `target(+PidOrQueue)`

The calling process does not get variable bindings directly. Instead, the
toplevel sends answer messages such as:

- `success(Pid, Data, More)`
- `failure(Pid)`
- `error(Pid, Error)`

The toplevel may also send arbitrary other messages, including `output/2` and
`prompt/2`, depending on the executed goal.

#### `toplevel_next/1-2`

```prolog
toplevel_next(+Pid) is det.
toplevel_next(+Pid, +Options) is det.
```

Requests more solutions from a previously active toplevel.

Supported options:

- `limit(+Integer)`
- `target(+PidOrQueue)`

If an option is omitted, the toplevel keeps using the most recent value from
the earlier call state.

#### `toplevel_stop/1`

```prolog
toplevel_stop(+Pid) is det.
```

Asks the toplevel to stop paging further solutions.

#### `toplevel_abort/1`

```prolog
toplevel_abort(+Pid) is det.
```

Interrupts the currently running goal inside the toplevel actor.

### Predicates for Programming with Statechart Actors

#### `statechart_spawn/1-2`

```prolog
statechart_spawn(-Pid) is det.
statechart_spawn(-Pid, +Options) is det.
```

Spawns a statechart interpreter actor.

Exactly one source option must be supplied:

- `load_uri(+URI)`
- `load_text(+Text)`

All remaining options are passed to `spawn/3`.

`load_list/1` and `load_predicates/1` are rejected for statechart actors.

#### `raise/1`

```prolog
raise(+Event) is det.
```

Enqueues `Event` on the internal event queue of the current statechart
interpreter. It is meaningful only inside executable statechart content.

### Predicates for Programming with Supervisor Actors

#### `supervisor_spawn/2-3`

```prolog
supervisor_spawn(+ChildSpecs, -Pid) is det.
supervisor_spawn(+ChildSpecs, -Pid, +Options) is det.
```

Spawns a supervisor actor and starts its children.

Supported options:

- `strategy(+Strategy)`
- `intensity(+Integer)`
- `period(+Integer)`
- `name(+Name)`

Other options are passed through to `spawn/3`.

Child specs have the form:

```prolog
child(Id, ChildOptions)
```

Supported child options:

- `start(+Goal)`
- `restart(+Policy)`
- `shutdown(+Shutdown)`
- `type(+Type)`

Dynamic/query operations:

- `supervisor_spawn_child/3`
- `supervisor_terminate_child/3`
- `supervisor_delete_child/3`
- `supervisor_respawn_child/3`
- `supervisor_which_children/2`
- `supervisor_count_children/2`
- `supervisor_stop/1`

The current reply shapes are the ones implemented in
[`supervisor_actor.pl`](supervisor_actor.pl),
for example:

- `ok`
- `ok(NewPid)` for respawn
- `error(already_present)`
- `error(start_failed)`
- `error(running)`
- `error(not_found)`

`supervisor_which_children/2` returns `info(Id, Pid, Type, Restart)` terms.

`supervisor_count_children/2` returns:

```prolog
[specs-N, active-N, supervisors-N, workers-N]
```

These synchronous calls may throw:

- `supervisor_down(Reason)`
- `supervisor_call_timeout(Sup, Request)`

### Built-in Predicates for RPC

#### `rpc/2-3`

```prolog
rpc(+URI, +Goal) is nondet.
rpc(+URI, +Goal, +Options) is nondet.
```

Runs `Goal` remotely through the stateless `/call` API.

Supported options:

- `limit(+Integer)`
- `once(+Boolean)`
- `timeout(+Number)`
- `http_timeout(+Number)`
- `load_text(+AtomOrString)`
- `load_list(+ListOfClauses)`
- `load_uri(+URI)`
- `load_predicates(+ListOfPredicateIndicators)`

The remote execution timeout is capped by the node owner's timeout setting.
`http_timeout/1` controls only the client-side HTTP transport timeout.

#### `promise/3-4`

```prolog
promise(+URI, +Goal, -Ref) is det.
promise(+URI, +Goal, -Ref, +Options) is det.
```

Starts an asynchronous stateless remote call.

In the current implementation, supported options are:

- `template(+Template)`
- `offset(+Integer)`
- `limit(+Integer)`

The promised answer is later retrieved with `yield/2-3`.

#### `yield/2-3`

```prolog
yield(+Ref, ?Answer) is det.
yield(+Ref, ?Answer, +Options) is det.
```

Waits for the promised answer belonging to `Ref`.

This must be called from the same process that created the promise.

Supported options:

- `timeout(+Number)`
- `on_timeout(+Goal)`

### Built-in Predicates for Node Deployment

#### `node/1-2`

```prolog
node(+Port) is det.
node(+Port, +Options) is det.
```

Starts the HTTP server for a node.

In this repository, the node exposes:

- `/`
- `/call`
- `/toplevel_spawn`
- `/toplevel_call`
- `/toplevel_next`
- `/toplevel_poll`
- `/toplevel_stop`
- `/toplevel_abort`
- `/toplevel_respond`
- `/shell`
- `/ws`

Owner-controlled settings:

- `node:cache_size`
  Maximum number of stateless `/call` continuation cache entries.
  Default is `100`.
- `node:timeout`
  Owner timeout cap in seconds. Default is `2`.

Node startup options for the shared database:

- `load_shared_db_text(+Text)`
- `load_shared_db_file(+File)`
- `load_shared_db_uri(+URI)`

The shared database is loaded once into a dedicated runtime module and imported
by actor modules. It is not copied into every actor.

### Stateful WebSocket API

The WebSocket ACTOR profile lives at `/ws`.

Supported commands from client to server:

- `toplevel_spawn`
- `toplevel_call`
- `toplevel_next`
- `toplevel_stop`
- `toplevel_abort`
- `toplevel_respond`
- `spawn`
- `send`
- `exit`

Supported event types from server to client:

- `spawned`
- `success`
- `failure`
- `error`
- `output`
- `prompt`
- `timeout`
- `stop`
- `abort`
- `responded`
- `down`

### Semi-stateful HTTP API

The semi-stateful API is built on long-lived toplevel actors plus per-session
queues.

Endpoints:

- `/toplevel_spawn`
- `/toplevel_call`
- `/toplevel_next`
- `/toplevel_poll`
- `/toplevel_respond`
- `/toplevel_stop`
- `/toplevel_abort`

Current response vocabulary:

- `/toplevel_spawn` -> `spawned` or `error`
- `/toplevel_call`, `/toplevel_next`, `/toplevel_poll` ->
  `success`, `failure`, `error`, `output`, `prompt`, `timeout`, or `abort`
- `/toplevel_respond` -> `responded` or `error`
- `/toplevel_stop` -> `stop`
- `/toplevel_abort` -> `abort`

Pid parameters accept integer forms and canonical `Id@Node` forms.

### Stateless HTTP API

The stateless API is exposed at `/call`.

Important parameters:

- `goal`
- `template`
- `offset`
- `limit`
- `load_text`
- `timeout`
- `format`
- `once`

Only `goal` is required.

Although the API is stateless from the client's perspective, the server may
cache a live toplevel actor internally to continue paged solution retrieval
without recomputing earlier work.

## Concrete Example and Table Corrections

This section is a second pass over the draft's concrete examples and API tables.
It is meant to be copied from when updating the manual text.

### Pid Encoding by Surface

| Surface | Accepted pid input | Output pid shape | Notes |
| --- | --- | --- | --- |
| Prolog API / REPL | integer or `Id@Node` | canonical Prolog term `Id@Node` | Local integer pids are canonicalized using the current node URL. If no node has registered a self URL yet, the default is `http://localhost`. |
| HTTP query parameters | integer text or Prolog text `Id@Node` | n/a | Global pid values are sent as URL-encoded Prolog text, e.g. `5219496234@'http://localhost:3011'`. |
| HTTP JSON responses | n/a | local pid -> integer; non-local pid -> string `"Id@Node"` | This is a backward-compatibility choice in [`node_response.pl`](node_response.pl). |
| WebSocket JSON commands | integer or string `"Id@Node"` | n/a | The `pid` string must be parseable as a Prolog pid term. |
| WebSocket JSON events | n/a | local pid -> integer; non-local pid -> string `"Id@Node"` | Event payloads are always JSON. |
| Shell UI display | n/a | may display local `Id@Node` as `Id` | This is display-only and is controlled by the "Hide local node in pid" checkbox in [`shell.html`](shell.html). |

### Corrected Example Snippets

#### Local actor and toplevel pids

```prolog
?- self(S).
S = 1622453732@'http://localhost'.

?- spawn(true, Child, [monitor(true)]).
Child = 3457366593@'http://localhost'.

?- receive({M -> writeln(M)}, [timeout(2)]).
down(3457366593@'http://localhost',3457366593@'http://localhost',true)
true.

?- toplevel_spawn(Pid, [session(true), monitor(true)]).
Pid = 42103437@'http://localhost'.

?- toplevel_call(Pid, between(1,5,I), [template(I), limit(2)]).
true.

?- flush.
Shell got success(42103437@'http://localhost',[1,2],true)
true.
```

The important corrections are:

- pids are shown in canonical `Id@Node` form in the Prolog API
- `monitor(true)` installed during `spawn/3` uses `Ref = Pid`
- `toplevel_next/1` in the Prolog API inherits the previous paging limit

#### HTTP `/toplevel_spawn` response shape

Prolog response:

```text
spawned(5219496234@'http://localhost:3011').
```

JSON response for a local pid on that node:

```json
{"type":"spawned","pid":5219496234}
```

JSON response for a non-local pid relayed through JSON:

```json
{"type":"spawned","pid":"5219496234@'http://localhost:3011'"}
```

#### WebSocket pid usage

Sending to a remote pid through `/ws` should use a JSON string containing a
round-trippable Prolog pid term:

```json
{"command":"send","pid":"2189373363@'http://localhost:3011'","message":"hello"}
```

### Current HTTP Endpoint Table

| Endpoint | Required parameters | Optional parameters | Current responses |
| --- | --- | --- | --- |
| `/toplevel_spawn` | none | `format` (`json` default), `options` (`[]` default), `load_text` (`''` default) | `spawned`, `error` |
| `/toplevel_call` | `pid`, `goal` | `template` (defaults to `goal`), `offset` (`0`), `limit` (effectively unlimited), `format` (`json`), `load_text` (`''`), `once` (`false`), `timeout` (owner-capped) | `success`, `failure`, `error`, `output`, `prompt`, `timeout`, `abort` |
| `/toplevel_next` | `pid` | `limit` (effectively unlimited), `format` (`json`), `timeout` (owner-capped) | `success`, `failure`, `error`, `output`, `prompt`, `timeout`, `abort` |
| `/toplevel_poll` | `pid` | `format` (`json`), `timeout` (owner-capped) | `success`, `failure`, `error`, `output`, `prompt`, `timeout`, `abort` |
| `/toplevel_respond` | `pid`, `input` | `format` (`json`) | `responded`, `error` |
| `/toplevel_stop` | `pid` | `format` (`json`) | `stop` |
| `/toplevel_abort` | `pid` | `format` (`json`) | `abort` |
| `/call` | `goal` | `template` (defaults to `goal`), `offset` (`0`), `limit` (effectively unlimited), `format` (`json`), `load_text` (`''`), `once` (`false`), `timeout` (owner-capped) | `success`, `failure`, `error` |

Notes:

- `/toplevel_spawn` accepts spawn data either from query parameters or from a
  JSON POST body. In the JSON body, `options` may be a list, string, or atom-like
  string accepted by the parser in
  [`node_isotope_options.pl`](node_isotope_options.pl).
- `/toplevel_spawn` always forces `session(true)` and injects the ISOTOPE
  prelude `writeln/1 -> actor:output/1`.
- For JSON responses, `format=json` also changes template handling in
  `/toplevel_call` and `/call`: named query variables are returned as JSON dicts
  rather than using the caller's explicit Prolog template text.
- The HTTP wrappers currently default omitted `limit` on `/toplevel_next` to an
  effectively unbounded value. That differs from `toplevel_next/1` in the
  Prolog API, which inherits the previous limit.

### Current WebSocket Command Table

| Command | Required fields | Optional fields | Notes |
| --- | --- | --- | --- |
| `toplevel_spawn` | `command` | `options` | Forces `session(true)`, `target(Queue)`, and `link(false)` and injects the same `writeln/1` prelude as ISOTOPE. |
| `toplevel_call` | `command`, `pid`, `goal` | `template`, `limit`, `offset`, `once`, `load_text`, `format` | `format` affects template parsing semantics, not transport encoding; events remain JSON. |
| `toplevel_next` | `command`, `pid` | `limit` | Omitted `limit` currently defaults to an effectively unbounded value. |
| `toplevel_stop` | `command`, `pid` | none | Emits a `stop` event immediately after calling `toplevel_stop/1`. |
| `toplevel_abort` | `command`, `pid` | none | Emits an `abort` event immediately after calling `toplevel_abort/1`. |
| `toplevel_respond` | `command`, `pid`, `input` | none | Emits `responded`. |
| `spawn` | `command`, `goal` | `options` | Builds a bare actor with `target(Queue)` and `link(false)` and may still include user `monitor(true)` / `node(...)` options. |
| `send` | `command`, `pid`, `message` | none | `message` is parsed as Prolog term text. |
| `exit` | `command`, `pid` | `reason` (`kill` default) | `reason` is parsed as Prolog term text when possible. |

### Current WebSocket Event Table

| Event type | Fields | Notes |
| --- | --- | --- |
| `spawned` | `pid` | Sent for both bare actors and toplevel actors created over the connection. |
| `success` | `pid`, `data`, `more` | `data` is serialized from the answer template. |
| `failure` | `pid` | No more solutions. |
| `error` | `data` or `pid`, `data` | Protocol-level parser errors have no `pid`; actor/toplevel execution errors include `pid`. |
| `output` | `pid`, `data` | Used by `actor:output/1-2` and the injected `writeln/1` prelude. |
| `prompt` | `pid`, `data` | Used for actor input requests. |
| `timeout` | `pid` | Timeout while waiting for the next session event. |
| `stop` | `pid` | Acknowledges `toplevel_stop`. |
| `abort` | `pid` | Acknowledges `toplevel_abort`. |
| `responded` | `pid` | Acknowledges `toplevel_respond`. |
| `down` | `pid`, `reason` | External WebSocket protocol uses `down(Pid, Reason)` rather than the internal `down(Ref, Pid, Reason)` form. |
