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
