# Node-resident service example

This example separates two concerns:

- `node_resident_services.pl` is owner-local bootstrap code that starts durable actors and publishes them through the service registry.
- `service_directory.pl` is the public shared-database directory that clients can query with `rpc/2-3`.

That split is intentional: ordinary `register/2`, `whereis/2`, and
`unregister/1` remain available for client-managed actor names, while
node-resident services are installed with the owner-only
`register_service/2` and `unregister_service/1` API.

## Owner setup

Start a node that publishes the service directory and starts the named
services:

```prolog
?- [load].
?- use_module('examples/services/node_resident_services.pl').
?- start_service_demo_node(3010).
?- self_node_url(NodeURL).
NodeURL = 'http://your-node-name:3010'.
true.
```

Use that `NodeURL` value, or the node's advertised `/node_info` URL, when
addressing named services. On one machine this is often not literally
`http://localhost:3010`.

`start_service_demo_node/1` is the owner bootstrap entry point: if the node
is restarted and the owner runs the same bootstrap again, the `counter` and
`pubsub_service` actors are started and registered again.

If you want the service pids at startup, use:

```prolog
?- start_service_demo_node(3010, CounterPid, PubSubPid).
CounterPid = 1234567890@'http://localhost:3010',
PubSubPid = 1234567891@'http://localhost:3010'.
```

For manual control instead of the combined bootstrap, you can still start the
services yourself:

```prolog
?- node(3010, [profile(actor), load_shared_db_file('examples/services/service_directory.pl')]).
?- start_example_services(CounterPid, PubSubPid).
```

Or start them one at a time:

```prolog
?- start_counter_service(Pid).
?- start_pubsub_service(Pid).
```

Stop them again with:

```prolog
?- stop_example_services.
true.
```

## Counter service

Client A:

```prolog
?- [load].
?- self(Self).
Self = 51230945@'http://localhost'.
?- counter@NodeURL ! count(Self),
   receive({count(Count) -> true}).
Count = 1.
```

Client B:

```prolog
?- [load].
?- self(Self).
?- counter@NodeURL ! count(Self),
   receive({count(Count) -> true}).
Count = 2.
```

Back on client A:

```prolog
?- counter@NodeURL ! count(Self),
   receive({count(Count) -> true}).
Count = 3.
```

The point is that `counter` is no longer a private helper actor. Once the
node owner starts it and registers the stable name, it behaves like a shared
stateful service.

## Publish-subscribe service

Subscriber:

```prolog
?- [load].
?- self(Self),
   pubsub_service@NodeURL ! subscribe(Self),
   receive({msg(Message) -> true}).
Message = hello.
```

Publisher:

```prolog
?- [load].
?- pubsub_service@NodeURL ! publish(hello).
true.
```

This exposes shared coordination rather than shared state: clients interact
through one long-lived named actor.

## Discovery through `rpc/2`

Because the node publishes `service/2` in its shared database, clients can
discover the advertised services declaratively:

```prolog
?- [load].
?- rpc(NodeURL, service(Name, Meta)).
Name = counter,
Meta = meta(actor, protocol(count_v1)) ;
Name = pubsub_service,
Meta = meta(actor, protocol(pubsub_v1)).
```

This keeps discovery separate from process introspection. Clients learn only
the names that the node owner chose to publish.

## Discovery hub

`discovery_hub.pl` and `discovery_directory.pl` take that idea one step
further: instead of a node publishing *its own* services, a **discovery hub**
(node **n0**) publishes a live register of *other* nodes, queryable through
the same `/call` API. Service discovery is then just a query — finding a node
is running a goal against the hub's database. The full design is in
[`docs/DISCOVERY_HUB_PLAN.md`](../../docs/DISCOVERY_HUB_PLAN.md); this is
slice 1 (probe-only, no self-registration).

Two files, mirroring the service-directory split:

- `discovery_hub.pl` — owner-local bootstrap. Starts n0 as an `actor` node
  and runs the **registry custodian**: a `receive`-loop actor that holds the
  records, and on a 30s heartbeat fans out one transient prober per node to
  fetch `/node_info`, folds the results in, and republishes a
  generation-buffered read replica.
- `discovery_directory.pl` — the hub's shared database (the read side). Turns
  the replica back into queryable relations; `node_status/2` is **derived at
  read time** (up / amber `unreachable` / down) from observed timestamps, so
  a dead node cannot leave a stale `up` stranded.

Start a hub (after `?- [load].`):

```prolog
?- use_module('examples/services/discovery_hub.pl').
?- start_discovery_hub(3060).
```

Then discovery is a query against the hub over `/call`:

```prolog
?- rpc('http://localhost:3060', node_record(n0, R)).
?- rpc('http://localhost:3060', (node_profile(N, actor), node_status(N, up))).
```

The default seed lists the public n1–n5 nodes; override it for a local demo
or test with `set_seed/1` before starting:

```prolog
?- set_seed([ seed_node(n1, 'http://localhost:3071',
                        "a local peer", "its shared db", "") ]).
?- start_discovery_hub(3060).
```

The browser demonstrator's intro panel renders this register as a live
**directory** (status dots, a ~10s poll, and graceful fallback to the static
seed when the hub is unreachable). The hub URL the directory queries is the
`PORTAL_HUB_URL` constant in `web/demonstrator.html` (empty = same origin, so
the node serving the page is itself the hub).

Tests: [`tests/discovery_hub_tests.pl`](../../tests/discovery_hub_tests.pl)
(status derivation + a hub/peer integration pass).

> **Schema note.** The plan sketches the membership relation as `node/1`;
> the implementation uses `node_id/1`, because the node server already owns
> `node/1` and the hub's shared module would otherwise shadow it.
