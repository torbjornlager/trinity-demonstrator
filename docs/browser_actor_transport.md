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
leaving a local `receive/1` blocked.  It must also treat socket closure as a
transport failure for all pending requests.  Full remote `monitor/2`,
`demonitor/2`, `down/3`, exit, and reconnect semantics are the remaining
implementation milestones; connection closure must eventually produce
deterministic `down/3` messages for browser-installed monitors.

## Compatibility

The wire version will be negotiated before a client relies on optional
features.  Version 1 is backward-compatible with existing `/ws` command
names and event shapes; additions must be capability-gated and preserve
unknown-event tolerance.
