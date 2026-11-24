# Third-party actor sends across N3, N4, N5 and N7

Status, 24 November 2026: Phase 0 cases written (trinity-conformance branch
`cross-node-actor`, baseline recorded). Phase 1 released on live N5 from
trealla-port branch `third-party-send`. Phase 2 released on live N7 from
eclipse-node branch `n7-third-party-send`, with an N5 follow-up from
trealla-port branch `browser-reply-pids`. XN-001 to XN-004 pass on all 148
combinations over N3, N4, N5 and N7, from every caller. Phase 3 and Phase 4
not started.

## Problem

A program that knows a pid should be able to send to it, whichever node holds
the pid and whichever node the sender runs on. Today that holds only between
the SWI nodes. This program hangs:

```prolog
ping_pong :-
    spawn(pong, Pong_Pid, [node('https://n5.elfenbenstornet.se'),
                           src_predicates([pong/0]), monitor(true)]),
    spawn(ping(3, Pong_Pid), Ping_Pid, [node('https://n7.elfenbenstornet.se'),
                                        src_predicates([ping/2]), monitor(true)]),
    receive({down(Pong_Pid, _, true) -> true}),
    receive({down(Ping_Pid, _, true) -> true}).
```

Measured against the live nodes on 24 November: a receiver spawned by the
calling shell on node B, a sender spawned by the same shell on node A, and
A sends `hello` to the receiver.

| A → B | From N3 | From N4 | From N5 |
|---|---|---|---|
| N3 → N4 | ok | ok (B is caller) | ok |
| N3 → N5 | ok (A is caller) | lost | lost |
| N3 → N7 | ok (A is caller) | lost | lost |
| N4 → N3 | ok (B is caller) | ok | ok |
| N4 → N5 | lost | ok (A is caller) | lost |
| N4 → N7 | lost | ok (A is caller) | lost |
| N5 → N3 | ok | ok | ok |
| N5 → N4 | ok | ok | ok |
| N5 → N7 | lost | lost | lost |
| N7 → N3 | ok (B is caller) | lost | lost |
| N7 → N4 | lost | ok (B is caller) | lost |
| N7 → N5 | lost | lost | lost |

Every lost row has a target on N5 or N7, or a sender on N7.

## Causes

1. **N5 (trealla-port) accepts a WebSocket `send` only for an actor spawned over
   that same connection.** `relay_command(send, …)` resolves the target with
   `owned_pid/5`, which requires `relay_actor/3` on this connection and the
   same lineage namespace (`receiver_lineage:check_actor/1`). Any other target
   gets `permission_error(access, web_prolog_actor, Pid)`. N5's audit log still
   records the request as `success`, and the SWI sender drops the error frame
   (`best_effort(remote_send_command/2)`), so the message just disappears.
2. **N5 exports its local pids as per-connection return addresses.**
   `portable_term_for_writer/3` turns a local pid into `Id@localhost`, a handle
   valid only on that one connection, and SWI imports it as
   `browser_actor(Conn, Id@localhost)`. A third node can't route to it.
3. **N7 (eclipse-node adapter) is connection-scoped throughout.** An inbound
   `send` is accepted only for a pid in that connection's own `sessions` or
   `actors`. An outbound `peer_send` goes only to the peer that connected
   (`relay_peer_terminal`: any other node is marked failed). Its pids leave as
   bare integers. The isolation probe (`check_foreign_commands`) asserts the
   foreign-send rejection.

SWI (N3, N4) already gets this right. `ws_require_send_target/3` lets a
principal with `internal_transport` send to any local actor, and its pids are
always `Id@'https://nX…'`. SWI needs no semantic change.

## Target rule (all four nodes)

- An authenticated peer node (a principal with `internal_transport`) may
  `send` to any live local actor.
- Browsers and anonymous clients keep connection ownership, as on SWI today.
- `exit`, `monitor`, `demonitor`, halt and toplevel commands stay owner-only.
- Pids sent to a peer node are qualified as `Id@PublicURL`. A node without a
  public URL, or a browser connection, keeps today's return-handle scheme.
- Admission is unchanged: frame size, term depth, mailbox limits, rate limits.

This restores language semantics, so nothing goes into DEVIATIONS.md. The
implementations' READMEs, which describe actors as "connection-owned", get
updated.

## Phase 0: Conformance first (trinity-conformance)

- Add a multi-node case group (`XN-*`) to `cases/` and `runner/run.py`:
  - XN-001: the send matrix above, every ordered pair from each actor node as
    caller.
  - XN-002: a pid from `self/1`, sent to a third node, is `Id@URL` and can be
    replied to.
  - XN-003: ping-pong with pong and ping placed on any two nodes.
  - XN-004: a browser or anonymous foreign `send`, and any foreign `exit` or
    `monitor`, are still refused.
- Record a baseline report against live. The lost rows should fail and
  everything else should pass.

## Phase 1: N5 (trealla-port)

1. `relay_command(send, …)`: when the connection principal has
   `internal_transport` and the target is a live local actor, deliver it
   without the relay-ownership and lineage-namespace check. Published services
   are unchanged. `owned_pid/5` stays as it is for every other command.
2. `portable_term_for_writer/3`: when `web_prolog:current_node_url/1` is set and
   the writer is a node-peer connection, export local pids as `Pid@URL`.
   Inbound `Pid@URL` for this node already resolves locally
   (`actors:hook_send(WirePid@Node0, …)`).
3. Tests: unit tests for both rules (a browser foreign send is still refused).
   Extend `swi_websocket_interop.pl` with a three-node case (SWI sender,
   Trealla receiver spawned by another connection).
4. README: replace "connection-owned" with the rule above for sends.

No credential changes are expected. N3 and N4 already hold outbound tokens for
N5, N5 reaches N3 and N4 over the private network, and N5 holds a token for N7.
The rehearsal confirms this.

## Phase 2: N7 (eclipse-node adapter)

0. Prerequisite: fix the deadline restart first. On 24 November the
   cross-node test traffic restarted live N7 four times (14:27, 15:01, 15:03
   and 15:06 UTC). Each time a request to the ECLiPSe backend exceeded the
   bridge's 6 s request deadline (`Bridge.request` in `isotope_http.py`).
   `Bridge.fail` then calls `on_failure`, the adapter exits, and Docker
   restarts the container, ending every N7 session.

   Status: reproduced and root-caused in an isolated lab, and released on live
   N7 at 17:43 UTC on 24 November (eclipse-node branch `n7-relay-robustness`
   `0b1903c`). Details are in the private operator notes. The fix has two
   parts:
   - engine: an actor's relay that fails reports the actor as down instead of
     stopping silently;
   - adapter: a request about one WebSocket actor that gets no reply fails on
     its own; only engine-wide requests still restart the node.

   A Trealla bug produced the trigger by accident; it is fixed in Phase 1.

All Phase 2 work runs against a local N7 built from the same images first.

1. Peer-spawned actors already share one engine (`server.bridge`), and
   `bridge.ws_actors` already maps each pid to its owning connection.
   Browser sessions get separate public engines. An adapter-wide registry maps pid → owning connection and engine. Pids must
   be unique across engines: allocation checks the registry and reallocates on
   collision.
2. Inbound: a `send` on any authenticated actor-peer connection to a pid in the
   registry goes to the owning engine through the existing bridge request.
   Browser connections keep the per-connection check.
3. Outbound: `peer_send` goes to any configured `--actor-peer` origin (N3, N4,
   N5) with that peer's outbound credential, or to another local engine
   through the registry. Other destinations are dropped and logged.
4. Export: in frames to peers, the adapter rewrites engine-local pids to
   `Id@'https://n7.elfenbenstornet.se'`, and resolves the inbound form back.
5. Isolation is unchanged. Engines stay per-connection with `--network none`,
   and actors still end when their owning connection closes. The adapter
   relays messages only, with no new execution path.
6. Tests: adapter unit tests. Update `probe_actor_pingpong.pl`: a foreign
   browser `send` is still refused, a foreign peer `send` is accepted, and a
   foreign `exit` is still refused.

N7 already has actor-peer credentials for N3, N4 and N5. Phase 2 widens the
adapter's role, and the adapter still runs as root with the Docker socket
(security review H2). See the open decisions.

## Phase 3: SWI (optional, swi-prolog-node)

No semantic change. Optionally log refused remote `send` frames on the sending
node: the program still sees nothing, as in Erlang, but operators get a
record.

## Phase 4: Erlang parity for monitor/2 and exit/2

Goal: any authenticated peer node may also `monitor/2` and `exit/2` any pid
it knows, as in Erlang. Phases 1 and 2 don't need this. Ping-pong's monitors
come from the spawning parent, which already owns both actors, and live
`down` messages from N5 and N7 arrived on 24 November.

Current state, from reading the code (not yet measured live):

| Command from a peer node | SWI (N3, N4) | Trealla (N5) | ECLiPSe (N7) |
|---|---|---|---|
| `send` | any actor | owner only | owner only |
| `monitor` | any actor (`ws_require_send_target/3`) | owner only (`owned_pid/5`) | owner only (`peer_monitor`) |
| `exit` | owner only (`ws_require_owned_actor/3`) | owner only | owner only |

1. `monitor/2` on N5 and N7, matching SWI. The receiving node keeps the monitor
   per foreign connection, removes it when that connection or the monitoring
   actor goes, and sends `down` back over that connection. Per-connection
   monitor limits apply (N7 has 16 today).
2. `exit/2` on all four nodes, SWI included. This is the largest grant: a peer
   can end an actor it didn't spawn. Spawn-tree cleanup and lineage reclamation
   must handle an actor that ends for a foreign reason, and the change belongs
   in the receiving node's audit log.
3. `link/1` and `unlink/1` aren't Web Prolog builtins today: links come only
   from `spawn/3`'s `link(true)`. Adding them is a language decision, and they
   would need the same cross-node treatment as `exit/2`.
4. Conformance: XN-005 (third-party monitor, including `down` after the
   monitoring connection closes) and XN-006 (third-party exit, with reason
   propagation to monitors and links). XN-004 narrows to browser and anonymous
   senders.

## Release

Each node follows the usual scoped procedure, and each live switch is
approved separately:

1. Upstream commits with tests, then a new pin in the demonstrator.
2. An image built with BuildKit secrets for the private repositories.
3. An isolated rehearsal: the predecessor, then the candidate with checks, then
   an injected failure and restore of the predecessor.
4. The live switch with scoped `up -d --no-build --pull never --no-deps`, and
   automatic rollback on any failed check.
5. Checks: `examples_live.py --compare` (every drawer example on N3, N4, N5 and
   N7 unchanged), XN-001 to XN-004 for the pairs the switched node takes part
   in, and the probes.

N5 goes first, then N7. After both, the full XN group must pass from every
caller, and the program above must work with any placement.

## Open decisions

1. Scope of the first release: `send` only (recommended), with `monitor/2` and
   `exit/2` following in Phase 4. Whether to add `link/1` and `unlink/1` to the
   language is a separate question.
2. Browser and anonymous senders keep connection ownership (recommended,
   matches SWI).
3. N7 ordering: Phase 2 before, after or together with H2 (non-root adapter,
   Docker socket proxy).

## Out of scope, noted

- An N5 actor that spawns on N7 and passes on the caller's terminal is refused
  with `remote_error('Invalid inherited peer terminal')` (N5 audit, 24
  November). Terminal inheritance across three nodes is a separate question.
