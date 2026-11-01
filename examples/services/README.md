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
is restarted and the owner runs the same bootstrap again, the `counter`,
`pubsub_service`, and `linda` actors are started and registered again.

If you want the service pids at startup, use:

```prolog
?- start_service_demo_node(3010, CounterPid, PubSubPid).
CounterPid = 1234567890@'http://localhost:3010',
PubSubPid = 1234567891@'http://localhost:3010'.
```

For manual control instead of the combined bootstrap, you can still start the
services yourself:

```prolog
?- service_directory_options(Options), node(3010, [profile(actor)|Options]).
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
Meta = meta(actor, protocol(pubsub_v1)) ;
Name = linda,
Meta = meta(actor, protocol(linda_v1)).
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

## Model and Jev text boundaries

The owner-installed model and Jev services accept native SWI strings or proper
lists of one-character atoms as prompt text. Numeric code lists, atoms, open
lists and multi-character list elements are rejected by the public prompt
guards. Existing nonempty prompt, conversation, response and admission limits
remain in force. The model actor (21) and model statechart (19) accept both text
forms, including history entries.

Provider requests convert known text fields to native strings for JSON; a
character list must not accidentally become a JSON array. Responses are decoded
from UTF-8 after checking the existing byte limit. Model answer text and Jev
score legends follow the node's selected language text mode: native strings by
default, character lists in the experimental portable-text configuration.
Jev's `provenance(Raw)` and caller-supplied JSON state retain native JSON types,
including the distinction between an empty string and an empty array. Owner
endpoint/key settings and Jev question descriptions also accept character lists;
their existing atom/string forms remain supported.

The [mock-only verification](../../docs/verification/model-jev-text-2026-10-25/REPORT.md)
covers both reading modes without contacting a provider or using a real API key.
These application services are examples, not portable built-in predicates.

## Linda tuple-space service

The owner installs both the service and its public application predicates.
Clients simply call `linda_out/1`, `linda_in/1`, `linda_rd/1`, `linda_inp/1`,
and `linda_rdp/1`; they do not load or implement a server or request protocol.
**25 linda.pl** in the Examples drawer contains usage examples only.

On n3, n4, or n5, two programs on the same node can communicate:

```prolog
% Alice publishes a message, then may disconnect.
?- linda_out(message(blue, hello)).

% Bob takes it in another session. He may start first: the call waits.
?- linda_in(message(blue, Message)).
Message = hello.

% Alice publishes shared data.
?- linda_out(setting(blue, colour, green)).

% Either user can read it repeatedly without removing it.
?- linda_rd(setting(blue, colour, Colour)).
Colour = green.

% Remove it when finished. A missing nonblocking read or take fails.
?- linda_inp(setting(blue, colour, green)).
```

`blue` is a group name chosen by the clients, not an access control. Each node
has a separate blackboard; clients select the same node to communicate. N5
retains its existing owner-only SSO policy. The service owns tuples independently
of client connections, but restarting it clears the blackboard.

### SWI owner setup (n3 and n4)

`node_resident_services.pl` starts Linda alongside the counter and pubsub
services. `start_service_demo_node/1` loads the service directory and
`linda_client.pl` into the shared database. Manual setup must load both:

```prolog
?- use_module('examples/services/node_resident_services.pl').
?- start_service_demo_node(3010).
```

`start_n3.pl` and `start_n4.pl` install the same shared client source and start
the owner service. For separate lifecycle control:

```prolog
?- use_module('examples/services/linda_service.pl').
?- start_linda_service(Pid).
?- stop_linda_service.
```

### Trealla owner setup (n5)

`compose.trealla-n5.yaml` builds the existing Trealla runtime as a zero-replica
build dependency and adds a small owner application image layer using
`Dockerfile.n5-linda`. No host source mounts are required. The layer installs
`linda_service_trealla.pl`, the same `linda_space.pl` implementation used by SWI,
and the same shared `linda_client.pl` interface.

`start_n5_linda.pl` starts the service before entering the usual Trealla listener.
The deployment entrypoint retains the existing maintenance/drain behavior.
The N5 shared-database file list adds the client predicates and Linda directory
entry. The runtime, private authentication, SSO, and source-origin policy remain
owned by the existing Trealla deployment.

Rebuild and recreate N5 with the active override:

```sh
docker compose -f Deployment/compose.yaml \
  -f Deployment/compose.trealla-n5.yaml --env-file Deployment/.env \
  up -d --build --no-deps wp_n5
```

### Owner implementation and verification

`linda_space.pl` holds tuples and pending requests in actor state. Tuples are
finite ground Prolog terms, duplicates are separate occurrences, the oldest
matching tuple is selected, and waiting requests are considered in arrival order.
The client predicates resolve the local service, correlate replies, monitor its
pid, and cancel interrupted requests. Client monitors remove abandoned waits.
Cancellation cannot undo a take already processed; a lost acknowledgement does
not establish whether an operation happened. The teaching service has no
persistence, quotas, or `eval` operation.

The usage patterns are inspired by the
[SICStus Linda documentation](https://sicstus.sics.se/sicstus/docs/latest4/html/sicstus.html/lib_002dlinda.html#lib_002dlinda).
Section 5 of [Multi-threading and Message Communication in Qu-Prolog](https://arxiv.org/pdf/cs/0404052)
provides a server example using a different implementation.

Run the SWI semantic and browser integration tests with `./tools/test.sh LINDA`.
`tools/test_linda_service.py` checks the five owner-supplied predicates over real
WebSocket sessions, including waiting consumers and use after disconnection.
