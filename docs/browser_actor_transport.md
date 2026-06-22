# Browser Actor Transport, version 1

This document defines the WebSocket transport used between a SWI-WASM
browser runtime and an ACTOR-profile Web Prolog node.  It is deliberately a
transport contract, not a browser UI contract: another WASM host can
implement it without the Discovery Hub or the demonstrator JavaScript.

## Connection and authority

A browser opens an outbound `wss://<node>/ws` connection.  The node applies
its normal WebSocket route, authentication, quota, and `Origin` policies.
Each connection owns the actors and toplevel sessions it creates.  On close,
the node reaps those resources.

Browser-local actors are represented to the node by connection-scoped
virtual recipients:

```prolog
browser_actor(ConnectionId, worker_actor(Id))
```

They are never accepted as client-supplied destination pids.  The node
creates them only by rewriting the sender supplied with a browser `send`
command, and can therefore route replies solely to the originating socket.
For version 1, `browser_from` is rewritten only when it is the first argument
of the sent message—the conventional actor reply-pid position. Other
occurrences are ordinary message data and are never rewritten.

## Pids

Remote server actor and toplevel pids use the standard distributed form:

```prolog
Id@'https://node.example'
```

The browser may retain an internal resource-kind table keyed by this pid;
the pid itself does not expose that implementation detail.  Legacy
`remote_toplevel(Id, URL)` values are accepted only for an in-memory upgrade
transition and are not part of version 1.

## Commands

Commands are JSON objects with a `command` field.  Prolog terms are supplied
as Prolog source text in the named term fields.

| Command | Required fields | Result/events |
| --- | --- | --- |
| `spawn` | `goal`, optional `options` | `spawned` |
| `send` | `pid`, `message`, optional `browser_from` | `actor_message` when a virtual browser recipient is addressed |
| `exit` | `pid`, optional `reason` | actor lifecycle events |
| `monitor` | `pid`, optional `ref` | installs a browser-owned monitor; the node later emits `down` |
| `demonitor` | `ref` | removes the browser-owned monitor |
| `toplevel_spawn` | optional `load_text`, `options` | `spawned` |
| `toplevel_call` | `pid`, `goal`, optional `template`, `limit`, `offset`, `once` | `success`, `failure`, `error`, `timeout` |
| `toplevel_next` | `pid`, optional `limit` | `success`, `failure`, `error`, `timeout` |
| `toplevel_stop` / `toplevel_abort` / `toplevel_halt` | `pid` | `stop` / `abort` / `halted` |

The node owns parsing and policy enforcement.  Browser runtimes must not
infer permissions from the advertised node profile.

## Events

Events are JSON objects with a `type` field.  Standard node events preserve
the established Web Prolog WebSocket protocol (`spawned`, `success`,
`failure`, `error`, `output`, `prompt`, `timeout`, `down`, and lifecycle
events).  A browser transport additionally accepts:

```json
{
  "type": "actor_message",
  "target": "worker_actor(2)",
  "message": "pong"
}
```

The browser delivers this to its local mailbox.  For remote toplevel calls,
the browser converts node result events into the normal local mailbox terms,
for example:

```prolog
success(42@'https://node.example', [plato], true)
```

## Lifecycle and recovery

Version 1 requires an implementation to surface remote errors rather than
leaving a local `receive/1` blocked. It must also treat socket closure as a
transport failure for all pending requests.

`monitor/2`, `demonitor/2`, `down/3`, and remote `exit/2` are implemented
for browser-owned remote actors and toplevels. A monitor installed as part of
`spawn/3` uses the remote pid as its reference; an explicit `monitor/2`
uses the supplied/generated reference. When the target exits, the browser
receives the normal local mailbox message:

```prolog
down(Ref, Pid, Reason)
```

Socket closure rejects pending requests and delivers
`down(Ref, Pid, connection_lost(URL))` for monitors associated with that
connection. Automatic reconnect, monitor restoration after reconnect, and
cross-connection naming/service recovery are not part of version 1.

## Compatibility

The wire version will be negotiated before a client relies on optional
features.  Version 1 is backward-compatible with existing `/ws` command
names and event shapes; additions must be capability-gated and preserve
unknown-event tolerance.
