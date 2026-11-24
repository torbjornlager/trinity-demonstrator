# Distributed nodes across machines: agenda

Status: **top priority**, recorded 24 November 2026. This is a plan and a
diagnosis, not a specification. Nothing here changes the language or the
current wire protocol.

## Goal

Web Prolog nodes run on different machines, owned by different people, and
talk to each other over defined protocols, with no protocol translation or
special-casing between implementations. A node may still have a network layer
written in another language than its Prolog engine, but that layer must
implement the same written specification as every other node. It must not be a
dialect of its own.

## Where we stand

On 24 November, after three releases in one day, third-party sends work across
N3, N4 (SWI), N5 (Trealla) and N7 (ECLiPSe). All 148 cross-node combinations in
`cross-node-actor-0.1` pass, from every caller. See
[THIRD_PARTY_SEND_PLAN.md](THIRD_PARTY_SEND_PLAN.md) and the HANDOVER entries.

Getting there exposed one new boundary problem after another. None of them
needed a change to Web Prolog's semantics; all of them sat between nodes:

| Problem found | Gap behind it |
|---|---|
| N7 restarted when an actor sent to `(Id@Node)@Node` | No single wire form for pids |
| Trealla and N7 sent their pids as bare integers | Same |
| A peer could send only to actors its own connection spawned | No rule for what a peer node may do |
| A send was lost when the owning connection closed right after the actor ended | No delivery rule on close |
| N7's browser engines could not reach a pid on a third node | Browser engines talk to other nodes as anonymous clients, not as part of their node |
| A remote spawn from the SWI-WASM browser node fails with an opaque `<js>(5,'Error')` (under investigation) | Same family: browser-to-node behaviour is unspecified |

## Diagnosis

The language and the transport (HTTP and WebSocket, terms as text, JSON
frames) are sound. What is missing is a **normative node-to-node layer**.

1. **A pid's meaning depends on the connection it travels on.** The wire
   carries `Id@URL`, bare `Id` (meaning "the sender's node"), per-connection
   return handles `Id@localhost`, and implementation-internal forms such as
   SWI's `browser_actor(Conn, Id)`. Every boundary rewrites them, and terms
   passed on to a third node break wherever one rewrite is missing. In Erlang a
   pid carries its node everywhere and nothing is rewritten.

2. **One endpoint serves two roles.** `/ws` is both "a browser terminal talks
   to a node" and "a node talks to a node". Browser concepts leaked into
   distribution: virtual reply handles, acknowledged terminal I/O, prompt
   correlation and connection ownership. A node that reaches another node
   without peer credentials, as N7's browser engines and the SWI-WASM node do,
   is treated as a browser, so its actors cannot act as node citizens.

3. **Behaviour is defined by an implementation, not a specification.**
   [CROSS_NODE_ARCHITECTURE.md](CROSS_NODE_ARCHITECTURE.md) describes SWI's
   mechanisms well, and
   [interoperability baseline 0.1](https://github.com/torbjornlager/trinity-conformance/blob/main/baselines/0.1.md)
   selects some observable obligations. Neither says what every node must do
   with a pid it received from a third node, what a peer may ask of it, or what
   happens to messages when a connection closes. Ports reverse-engineer SWI.
   Additive capability flags (`browser_pids`, `io_ack`, `answer_terms`,
   `prompt_correlation`, the sync subprotocol) multiply the combinations.

4. **Peer trust is tied to network position.** The reference model grants
   `internal_transport` to a request from a loopback or private-range address
   ([CROSS_NODE_ARCHITECTURE.md §4.2](CROSS_NODE_ARCHITECTURE.md)). That
   cannot work between machines on the open internet. The live nodes already
   use static pairwise bearer tokens instead, which grow as n² and are
   configured by hand.

5. **Cross-node behaviour was untested until now.** The conformance suite was
   almost entirely single-node. `cross-node-actor-0.1` (XN-001..004) is the
   first cross-node pack, so gaps surfaced on the live nodes.

## Agenda

In priority order. Each item ends with what "done" means.

### 1. Node-to-node specification (wire protocol 2 draft)

Write the distribution layer as its own document, separate from the browser
protocol. Most of it codifies what SWI already does; the rest settles the gaps
above.

- **Pid form:** on the node-to-node wire every pid is `Id@NodeURL`, always,
  inside messages, goals and reasons alike. A node maps `Id@SelfURL` back to
  its local pid. No other pid forms cross between nodes.
- **Node identity and authentication:** a handshake that establishes which node
  is connecting, independent of network position.
- **Peer rights:** which commands an authenticated node may issue and for which
  actors: `send` to any live actor (as released on 24 November), `spawn`, and,
  following Erlang, `monitor`, `exit` and links (Phase 4 of
  THIRD_PARTY_SEND_PLAN).
- **Delivery and ordering:** messages between a pair of actors arrive in send
  order; a message sent before an actor ends is delivered while the receiving
  node is reachable; what a sender observes when it is not.
- **Failure:** cross-node `down` and exit propagation, node loss, reconnection.
- **Layering:** the browser protocol (return handles, terminal I/O, prompts,
  answer terms) is a separate layer on top. Any node's actors, including actors
  in a browser engine or behind an adapter, use the node-to-node layer when
  they address another node.
- **Versioning:** what is negotiated, and what is simply required in version 2.

Done: a reviewed specification in this repository or trinity-conformance, with
the open questions resolved and recorded in OPEN_DECISIONS.md.

### 2. Cross-node conformance

Extend `cross-node-actor` beyond XN-001..004: third-party monitor and exit
(XN-005, XN-006), links, pid round trips through several nodes, delivery on
close, node loss and reconnection, ordering. Run it with nodes on separate
hosts, not only on one Docker network.

Done: the pack covers every rule in item 1 and runs against at least two
separate machines.

### 3. Peer identity and trust for the open internet

Replace network-position trust and hand-configured pairwise tokens with node
identities: for example signed node credentials or mutual TLS, tied to the node
URL. Connect this to discovery ([DISCOVERY_HUB_PLAN.md](DISCOVERY_HUB_PLAN.md)).

Done: a node on another machine can be admitted as a peer without editing every
other node's configuration, and without trusting its IP address.

### 4. Implementations

| Node | Distance to the goal |
|---|---|
| SWI (N1–N4) | Closest. Serves the protocol natively. Needs the item 1 pid and trust rules, and TLS and credentials when it is not behind the shared edge. |
| Trealla (N5) | Close. Serves the protocol natively. The nginx admission layer could move into the node. |
| ECLiPSe (N7) | The Python adapter is N7's network stack and sandbox (one engine per visitor, no network). Make it implement item 1 faithfully, including its browser engines; rewriting ECLiPSe's networking is not required. |
| GNU Prolog (N6) | ISOBASE only (HTTP); not an actor node. The same principle applies if it gains actors. |
| SWI-WASM (browser) | A browser engine is a client of other nodes. Under item 1 its actors either use node-level rules through a trusted node, or keep browser-level rights explicitly. Remote errors must reach Prolog as readable terms. |

Done: each actor implementation passes item 2 against every other one.

### 5. Deployment on separate machines

Each node with its own DNS name and TLS; no configuration that relies on
internal Docker aliases between nodes; per-node operations without access to a
shared host.

Done: at least one node of the federation runs on a different machine and
passes item 2 with the others.

## Non-goals and framing

- No change to Web Prolog's language semantics. Intentional observable
  changes, if any, go to DEVIATIONS.md as usual.
- An adapter that is a node's network layer and implements the written
  specification is acceptable. What has to go is translation between dialects
  and special cases for particular peers.

## Related documents

- [CROSS_NODE_ARCHITECTURE.md](CROSS_NODE_ARCHITECTURE.md): SWI's cross-node
  mechanisms and the current wire protocol 1.
- [THIRD_PARTY_SEND_PLAN.md](THIRD_PARTY_SEND_PLAN.md): the 24 November work
  and Phase 4 (monitor and exit parity).
- [DISCOVERY_HUB_PLAN.md](DISCOVERY_HUB_PLAN.md): the planned registry node.
- [TURNKEY_NODE_REQUIREMENTS.md](TURNKEY_NODE_REQUIREMENTS.md): running a
  production node on the open web.
- [OPEN_DECISIONS.md](OPEN_DECISIONS.md): decisions deliberately postponed.
