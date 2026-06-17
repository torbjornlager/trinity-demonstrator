# Discovery Hub Plan

A design for replacing the demonstrator's hand-maintained list of nodes
with a live **discovery hub**: a node whose database holds a register of
the other nodes and their profiles, queryable through the same `/call`
API every node already speaks.

The guiding idea is that, in Web Prolog, service discovery should not be
a bolted-on REST registry.  It is a **query**.  The hub is just another
node; finding a node is running a goal against its database.  This
document fixes the record schema, the registry actor protocol, the
liveness model, the trust boundary, and the directory UI.

Nothing here removes the existing n1–n5 header buttons; the hub is
strictly additive and degrades to today's behaviour when it is
unreachable.

> **Status (slice 1, as built).** The probe-only registry is implemented
> and tested: [`examples/services/discovery_hub.pl`](../examples/services/discovery_hub.pl)
> (the `registry_actor/1` custodian, transient probers, the 30s
> receive-timeout sweep, tier-respecting `apply_probe/4`, and the
> generation-buffered `publish_replica/2`) and
> [`examples/services/discovery_directory.pl`](../examples/services/discovery_directory.pl)
> (the stateless read side: `node_record/2` with status derived at read
> time, plus the `node_id/1` / `node_url/2` / `node_profile/2` /
> `node_auth/2` / `node_status/2` query relations). The browser directory
> is built in `web/demonstrator.html`'s intro panel, data-driven from a
> `/call` to the hub with status dots, the amber band, a ~10s poll, and
> fallback to the static seed. Tests:
> [`tests/discovery_hub_tests.pl`](../tests/discovery_hub_tests.pl).
> Resolved open questions for this slice: **probe transport** is plain
> HTTP `GET /node_info`; the membership relation is `node_id/1` rather
> than `node/1` (the node server owns `node/1`). Slices 2–4 (capability
> harvesting, the query builder, authenticated self-registration) remain
> as specified below.

---

## 1. Conceptual model

The current node list is already a registry — it is just frozen into the
browser.  The `splashNodeCards` computed property in
[demonstrator.html](../web/demonstrator.html) (around line 5141) renders,
per node, a title, a profile badge, a prose description, a shared-database
blurb, and the "open" links.  That hand-written array *is* the seed data;
this plan makes it live.

The hub is a node — by decision, not a thin sidecar.  Concretely it is an
**`actor`-profile node** (call it **n0**, the node you reach the others
through) running a single registry service alongside the existing
`counter` / `pubsub_service` examples.  Discovery is then a goal:

```prolog
?- node_profile(N, actor), node_auth(N, open).           % an open actor node
?- node_provides(N, human/1), node_status(N, up).        % who serves human/1, live?
```

The hub is the one **well-known root**: the single bootstrap constant the
client must still know.  We trade "five hardcoded nodes" for "one
hardcoded entry point" — the DNS-root / Consul-seed trade, and a good one.

This is deliberately *not* UDDI.  The whole register is a handful of
relations behind `/call`; the demonstration is that discovery in Web
Prolog is a program, not a protocol stack.

---

## 2. The record schema

### 2.1 Provenance tiers

Every field belongs to one of three tiers, distinguished by **where it
comes from** and therefore **how much it can be trusted**.  This tagging
is the schema's organising principle: it dictates what the probe loop may
overwrite and what it must leave alone.

| Tier | Source | Trust | Fields |
| --- | --- | --- | --- |
| **seed** | author-curated, in the hub's boot database | authoritative by fiat | `id`, `url`, `description`, `shared_db` |
| **self-reported** | the node's own `/node_info` endpoint | true if the node is honest; verifiable | `profile`, `auth`, `version`, `services`, `provides` |
| **hub-observed** | the hub measures it | authoritative; node cannot forge | `last_seen`, `last_error`, `latency_ms` |

Two rules fall straight out:

- **The hub never sources the seed tier from a node.**  A buggy or
  compromised node cannot rename itself or rewrite its URL in the
  directory; it can only move the fields we already chose to trust it for.
- **A node never reports its own liveness.**  Status is something the hub
  *decides* by probing — otherwise a dead node that lies stays "up"
  forever (see §4).

### 2.2 Normalized relations, not one fat tuple

The multi-valued fields (a node has many services and many provided
predicates) do not fit positional arguments, and a single wide tuple
becomes unreadable the moment it is extended.  The source of truth is a
set of **relations keyed by node id**:

```prolog
% --- seed tier ---
node(n3).
node_url(n3, 'https://n3.elfenbenstornet.se').
node_desc(n3, "The fully stateful node.  Adds /ws, actor messaging, services.").
node_shared_db(n3, "Common base + actor-common layer + n3 overlay.").

% --- self-reported tier (from /node_info, refreshed each probe) ---
node_profile(n3, actor).
node_auth(n3, open).
node_version(n3, "0.2.0").
node_service(n3, counter).            % one fact per service
node_service(n3, pubsub_service).
node_provides(n3, human/1).           % one fact per predicate
node_provides(n3, mortal/1).

% --- hub-observed tier ---
node_last_seen(n3, 1718900000).
node_latency_ms(n3, 42).
```

Discovery queries then compose the way Prolog wants them to — this is the
feature's payoff:

```prolog
?- node_profile(N, actor), node_auth(N, open), node_service(N, counter).
```

### 2.3 A composed dict for the wire and the UI

Normalized facts are good to query and miserable to ship one relation at
a time.  Pair them with a single composing predicate that assembles the
public record into a dict:

```prolog
node_record(Id, node{
    id: Id, url: Url, profile: Profile, auth: Auth,
    status: Status, last_seen: Seen, latency_ms: Latency,
    version: Version, services: Services, provides: Provides,
    description: Desc, shared_db: SharedDb
}) :- ...
```

The UI and external callers get one clean, versioned JSON object; the
internal store stays normalized and queryable.  Adding a field to the
dict does not disturb the relations.

### 2.4 The profile lattice is first-class

`relation < isobase < isotope < actor` is an order (see
[PROFILE_MATRIX.md](PROFILE_MATRIX.md)).  Discovery wants "at least
isotope", not exact match, so the ordering is exposed rather than left
for callers to know:

```prolog
profile_rank(relation, 0). profile_rank(isobase, 1).
profile_rank(isotope, 2).  profile_rank(actor, 3).

node_profile_at_least(N, Min) :-
    node_profile(N, P),  profile_rank(P, R),
    profile_rank(Min, RMin), R >= RMin.
```

### 2.5 Mapping to existing data

Almost nothing here is new data — it is relocating and lifting:

- `profile`, `auth` — straight from `node_info_page_1/1` in
  [node.pl](../src/node.pl) (line 1206), the handler registered at
  `/node_info` ([node.pl](../src/node.pl) line 225), which already returns
  `self_url`, `profile`, `auth`, and the trusted-header policy.
- `description`, `shared_db` — lifted verbatim from `splashNodeCards`;
  this is where that prose finally gets a real home.
- `version` — **not** server-exposed in this codebase: version appears only
  client-side (`web/demonstrator.html`, `web/admin.html`), with no
  `/version` endpoint to probe.  Harvesting it needs a small node-side
  endpoint, so it defers with `services` / `provides` (§9) rather than
  riding along in slice 1.
- `services` — the node tracks these (`whereis_service/2` in
  [actor.pl](../src/actor.pl)), but `node_info_page_1/1` does **not** expose
  them today, so harvesting them needs a small `/node_info` addition (or a
  new endpoint).  It is therefore *not* free: `node_service/2` defers
  alongside `provides`, past slice 1 (§9).
- `provides` — a genuinely new field; it needs a node-side endpoint that
  publishes the node's offered predicates.  Deferred past slice 1 (§9).

So the slice-1 self-reported tier is exactly what a node already exposes
over `/node_info`: `profile` and `auth`, and nothing else.  `version`,
`services`, and `provides` all arrive together once a node-side endpoint
publishes them.

---

## 3. The registry actor

### 3.1 Decomposition: a custodian that never blocks

The registry is the same shape as `count_actor/1` and `pubsub_actor/1` in
[node_resident_services.pl](../examples/services/node_resident_services.pl)
— a state-as-argument `receive` loop registered with `register_service/2`
— with two twists: it does IO (probing), and it must stay responsive
while doing it.

The cardinal rule: **the custodian holds state and must never block on a
network call.**  Roles are split the way the actor model wants:

- **`registry_actor/1`** — the custodian.  Holds the records, handles
  `register` / `deregister` / `nodes`, folds in probe results.  Pure
  mailbox work; never touches the network.
- **transient probers** — spawned per node per sweep, do the one blocking
  `/node_info` fetch, report the result back as a message, and die.  A slow
  node ties up only its own throwaway prober.
- **a clock** — the custodian's own `receive/2` timeout drives the sweep.

### 3.2 Message protocol

`receive/2` in [actor.pl](../src/actor.pl) (line 1617) does **not** loop: it
calls the matched clause body — or, on timeout, the `on_timeout` goal — and
returns whatever that returns.  So, exactly as `count_actor/1` does, **every
path must carry its own continuation by recursing**, and there is no trailing
call after the `receive`.  The timeout path is no exception: `on_timeout`
sweeps *and* re-enters.

```prolog
registry_actor(Nodes0) :-
    receive({
        register(Record, From) ->
            merge_record(Record, Nodes0, Nodes),
            From ! ok,
            publish_replica(Nodes),
            registry_actor(Nodes) ;

        deregister(Id) ->
            exclude([N]>>record_id(N, Id), Nodes0, Nodes),
            publish_replica(Nodes),
            registry_actor(Nodes) ;

        nodes(From) ->                       % live query path
            From ! nodes(Nodes0),
            registry_actor(Nodes0) ;

        probe_result(Id, Outcome) ->         % a prober reporting back
            apply_probe(Id, Outcome, Nodes0, Nodes),
            publish_replica(Nodes),
            registry_actor(Nodes)
    }, [
        timeout(30),                                  % no message for 30s →
        on_timeout(( sweep, registry_actor(Nodes0) )) % sweep, then re-enter
    ]).
    % NB: no recursion here — receive's body / on_timeout goal is the tail.

sweep :-
    self(Me),
    forall(known_node(Id, Url),
           spawn(probe_one(Id, Url, Me))).    % one transient prober each

probe_one(Id, Url, Registry) :-
    ( fetch_info(Url, Info) -> O = ok(Info) ; O = error ),
    Registry ! probe_result(Id, O).
```

The whole engine: a custodian, a 30-second heartbeat, and fan-out probers
reporting back into the same mailbox the registrations flow through.  Note
that `on_timeout`'s goal is resolved in the receive clauses' module
(`clauses_module/2`), so `registry_actor/1` must be visible there — qualify
it if the service lives in a separate module.

### 3.3 Refresh without clobbering the seed

`apply_probe/4` is where the tiers earn their keep.  The merge rule is
literally "which tier is this field in?":

- `ok(Info)` arrives → **overwrite the self-reported tier** from `Info`;
  **stamp the observed tier** (`last_seen := now`, record `latency_ms`);
  **leave the seed tier untouched**.  In slice 1 the self-reported tier is
  just `profile` and `auth` (all that `/node_info` exposes today); the later
  capability-harvesting phase (§9) widens it to add `version`, `services`,
  and `provides`.
- `error` arrives → touch nothing but `last_error := now`.  Crucially,
  **do not refresh `last_seen`** — that is what lets aging notice the node
  went quiet.

### 3.4 The read replica resolves the stateless/stateful split

The registry is an actor to its maintainers and a relation to its
consumers.  `publish_replica/1` makes that literally true: on every state
change the custodian republishes a denormalized read replica into the
node's database.

A naive `retractall` then `assertz` loop has a hazard: `/call` runs on a
different thread from the custodian, so a query landing mid-republish can
observe a partial (or empty) predicate.  The window is microseconds and
the next poll self-corrects, so the severity is low — but the fix is cheap
enough to take from the start.  **Double-buffer behind a generation
pointer**: build the new generation completely, flip a single
`current_gen/1` fact (asserting the new one *before* retracting the old),
then garbage-collect the previous generation.

During the brief overlap after `assertz(current_gen(Gen))` and before the
old pointer is retracted, *two* `current_gen/1` facts coexist, so a reader
that backtracked over `current_gen/1` could mix records from both
generations.  Both generations are complete at that moment, so the fix is
simply to commit each query to a *single* generation with a cut — never to
forbid the overlap.  With `assertz` appending, the cut takes the
first-asserted (older, still-complete) pointer until it is retracted, then
flips to the new one; no query ever spans two generations.

```prolog
:- dynamic node_record_gen/3.        % Gen, Id, Record
:- dynamic current_gen/1.

publish_replica(Nodes) :-
    next_gen(Gen),
    forall(member(N, Nodes), assert_record(Gen, N)),   % build new gen fully
    findall(Old, current_gen(Old), Olds),              % capture old pointers
    assertz(current_gen(Gen)),                          % flip: new is live
    forall(member(Old, Olds),                           % retire predecessors
           ( retract(current_gen(Old)),                 % (no mutex needed)
             retractall(node_record_gen(Old, _, _)) )). % GC old gen

node_record(Id, R) :-
    current_gen(G), !,                   % commit to one generation per query
    node_record_gen(G, Id, R).
```

There is one residual race the cut alone does not cover, and it depends on
the runtime's clause-visibility semantics.  A reader commits to generation
`G` at the cut, then resolves `node_record_gen(G, …)` a moment later — and
in between, `publish_replica/1` may `retractall` `G`'s records.  Under
SWI's **logical update view**, a goal sees the clause set as of when *that
goal's call started*, so a `node_record_gen/3` activation that has begun is
safe against a concurrent retract; but relying on that couples correctness
to the exact semantics, and a port to another Prolog may not give the same
guarantee.  The robust, semantics-independent default is to **delay GC by
one generation**: when publishing `Gen`, retire only generations older than
`Gen - 1`, so the immediately-previous generation a straggling reader may
have committed to is still intact.  (A mutex around the flip-plus-GC, with
readers taking it too, also works but adds reader contention — the
one-generation delay is cheaper and lock-free.)  This is the form to
implement — it supersedes the GC step in the sketch above, which retired the
previous generation immediately:

```prolog
publish_replica(Nodes) :-
    next_gen(Gen),
    forall(member(N, Nodes), assert_record(Gen, N)),   % build new gen fully
    findall(P, (current_gen(P), P \== Gen), Stale),    % capture old pointers
    assertz(current_gen(Gen)),                          % flip: new is live
    forall(member(P, Stale), retract(current_gen(P))),  % drop stale pointers
    GcBefore is Gen - 1,                                % keep Gen-1 for stragglers
    findall(Old, (node_record_gen(Old, _, _), Old < GcBefore), Olds0),
    sort(Olds0, Olds),
    forall(member(Old, Olds), retractall(node_record_gen(Old, _, _))).
```

Reads then hit plain `node_record/2` / `node_profile/2` facts — pure,
stateless `/call`, no message round-trip, no risk of a query hanging on a
busy actor, and no torn snapshot.  Writes go *through* the actor
(serialized, safe).  The actor is the single writer; the database is its
published, queryable shadow.

---

## 4. Liveness and aging

**Status is derived, not stored.**  The store keeps only `last_seen` and
`last_error`; "up / unreachable / down" is a view computed at read time
against the TTL.  This deletes an entire class of bug — there is no stored
`up` that can get stranded when a node dies between sweeps.

The derivation must compare the two timestamps, not just test `last_seen`
freshness in isolation.  A node that succeeded recently and then failed its
*next* probe has a fresh `last_seen` **and** a newer `last_error`; reporting
`up` on `last_seen` alone would hide the failure for up to a full TTL and
defeat the amber early-warning.  So `up` requires a fresh success that is
**not superseded by a newer error**:

```prolog
fresh(T)                :- now(N), N - T =< 75.
superseded_by_error(Id, T) :- node_last_error(Id, E), E > T.

node_status(Id, up) :-                       % fresh success, latest probe ok
    node_last_seen(Id, T), fresh(T),
    \+ superseded_by_error(Id, T), !.
node_status(Id, unreachable) :-              % fresh success, but newer probe failed
    node_last_seen(Id, T), fresh(T),
    superseded_by_error(Id, T), !.
node_status(Id, down).                        % stale, or never successfully seen
```

A node is up because we *recently and most-recently* heard from it, not
because someone once set a flag.  The amber `unreachable` band is exactly
"last success still fresh, but the latest probe failed" — one missed probe
after a good one — which is the early warning that hysteresis is meant to
surface.

Knobs, and where to stop:

- **Cadence** — one fixed 30s sweep is right for five nodes.  Adaptive
  backoff (probe `down` nodes less often) is the Consul-grade refinement;
  named, not built.
- **TTL ≥ ~2× interval** — 30s sweep, **75s TTL**.  One dropped probe must
  not flap a healthy node to `down`; two should.  This wide TTL band is
  also the UI's hysteresis (§6).
- **Jitter** — irrelevant at five nodes; matters only at dozens.

---

## 5. Security and trust

The read/query path stays **`open`**; the write/register path requires
**`private`** (an authenticated principal).  Otherwise a stranger could
advertise a fake "actor node" and poison the directory.

It is tempting to say the custodian stays "dumb about identity" and let
authority be enforced **at the HTTP boundary in front** — the node only
injects a `register` message if the request cleared the `private` boundary.
That is necessary but **not sufficient**, because the bridge is not the only
possible sender.  A registered service is reachable by name: in `actor`
profile a public user goal can do

```prolog
?- whereis_service(registry, P), P ! register(FakeRecord, self).
```

bypassing the `private` boundary entirely.  The "dumb actor" framing only
holds if the bridge is the *sole* injector, which a name-reachable service
is not.  Two mitigations, applied together:

1. **Keep the control pid off the public service registry.**  The
   query/read interface (`nodes/1`) may be a registered service; the
   *mutating* interface (`register` / `deregister`) goes to a separate pid
   known only to the HTTP handler, never published via `register_service/2`
   and so not discoverable with `whereis_service/2`.
2. **Carry an unforgeable capability.**  `register` includes a token the
   HTTP `private` boundary mints; the custodian verifies it before applying
   the change.  This is a small, correct concession to non-dumbness — the
   actor checks *possession of authority*, not identity.

Because the seed tier is never sourced from a probe (§2.1), probe-based
liveness sidesteps self-report trust entirely for the well-known nodes.
The first slice therefore ships **probe-only**, with no self-registration
at all — which also means the spoofing surface above does not exist yet.
It must be closed as a precondition of the registration phase (§9), not
after.

---

## 6. The directory UI

### 6.1 The splash cards are the directory

`splashNodeCards` already renders the seed-tier record.  The directory is
that component with its data source moved from the hardcoded array to a
`/call` against `node_record/2`, plus a live layer.  Same cards, fed by
the hub, with three additions: a status dot, filtering, and a visible
query.

### 6.2 Status that does not flicker

Each card gets a status dot derived as in §4.  The flap problem is solved
**in the colour mapping**, by making "unreachable" an explicit amber band:

- 🟢 **up** — `last_seen` fresh; card live, links active.
- 🟡 **unreachable** — last probe errored but within TTL.  This *is* the
  hysteresis: one missed probe shows amber, not red; the card stays
  usable.
- 🔴 **down** — stale past TTL; links dim, card sorts to the bottom.

The 75s TTL keeps the amber band wide enough to absorb a single miss, so a
node pulses yellow and recovers without ever flashing red — no debounce
timer needed.  A relative `last seen 12s ago` line and a light ~10s poll
of the replica make it a status board rather than a phone book.  Cheap
later win: give each kept header button (around line 5122 of
[demonstrator.html](../web/demonstrator.html)) the same dot from the same
fetch, so the buttons stop lying about dead nodes.

### 6.3 Filtering is query building

Three facets, each one conjunct of a goal:

- **Profile** — a segmented control over the lattice, using
  `node_profile_at_least/2`.  "≥ isotope", not "= isotope".
- **Auth** — open / private toggle.
- **Capability** — text/select over `node_service/2` or
  `node_provides/2`: "serves `human/1`".

### 6.4 The teaching surface: show the goal, then run it

Above the filtered cards, render the **actual goal the current filter
corresponds to**, live-updating as facets toggle:

```prolog
?- node_record(N, R),
   node_profile_at_least(N, actor),
   node_service(N, counter).
```

One button — **"Open in toplevel"** — drops that exact goal into the
terminal against the hub node.  The filter UI is a query builder; the
query is real and editable by hand.  This is the moment the directory
teaches something the button row never could.

---

## 7. Bootstrapping and failure

The hub is the one hardcoded bootstrap, so the UI must degrade
gracefully.  If the `/call` to the hub fails, the directory falls back to
the **static seed** (today's hardcoded `splashNodeCards`) and shows every
dot as ⚪ "status unknown — hub unreachable".  The screen is never empty;
the fallback is exactly the current behaviour.  The directory is strictly
additive.

The hub is itself a node, so **n0 appears in its own directory** —
self-referential and honest.  A one-line "this is the registry" tag on its
card makes that read as intentional.

---

## 8. Relationship to the existing buttons

The n1–n5 header buttons stay.  Two ways they relate to the hub:

1. **Independent** (slice 1) — buttons remain the hardcoded array; the hub
   is a parallel live view.  Zero coupling; no hub round-trip on load.
2. **Derived** (later) — buttons become a rendering of the hub's seed
   nodes and inherit live up/down state, so there is one source of truth
   and the buttons stop lying when a node is down.

Start independent; keep derived in reserve as the convergence point once
the hub proves itself.

---

## 9. Phasing

Be ruthless about the first slice.  Ship the architectural win — and the
graceful degradation — before any of the policy-heavy machinery.

**Slice 1 — the boring registry (the whole architectural bet).**
n0 as an `actor` node; `registry_actor/1` custodian + transient probers +
receive-timeout clock; seed n0 + n1–n5; probe `/node_info` only, so the
self-reported tier is `profile` + `auth` and **no node-side endpoint change
is required**; publish the generation-buffered
replica; `node_record/2` over `/call`; data-drive `splashNodeCards` from it
with status dots, the amber band, the ~10s poll, and **fallback to the
static seed when the hub is unreachable**.  No `services`, no `provides`, no
registration, no query builder, no derived buttons.  This proves the model
end to end with no front-loaded policy questions and no change to any node
but n0, and the spoofing surface of §5 does not exist yet because nothing
mutates the registry from outside.

Then, only once the registry has proven boring:

2. **Capability harvesting + query builder.**  Add the node-side endpoint
   that publishes `services` and `provides` (the first slice-1-external
   node change); lattice / auth / capability filters; the visible goal;
   "Open in toplevel".
3. **Authenticated self-registration** over the `private` boundary, with
   the §5 spoofing fix (off-registry control pid + verified capability) as
   a precondition, not a follow-up; `register` / `deregister`; TTL aging of
   self-registered nodes.
4. **(Optional)** derived buttons; adaptive probe backoff; registry
   federation/gossip between hubs.

---

## 10. Decisions and open questions

Resolved:

- **`provides` is owner-curated, not scraped.**  A node publishes a
  deliberate list of the predicates it offers as a contract, mirroring the
  owner-curated `service_directory.pl` rather than enumerating every public
  predicate.  Discovery is also documentation: the directory advertises what
  a node *promises*, not whatever happens to be loaded.

- **n0 advertises the narrowest honest public contract.**  It runs `actor`
  machinery internally (the registry custodian needs it), but its *public*
  surface is a stateless read of the replica, so it should advertise no more
  than that — not expose `/ws` and the full actor API publicly.  This is a
  decision, not just a preference, because it directly bounds the §5
  spoofing surface: if the registry pid is only reachable by code running
  *inside* n0 and n0 exposes no public actor surface, the
  `whereis_service/2`-then-send attack requires a foothold n0 does not hand
  out.  The remaining open part is mechanical (how to run `actor` internally
  while advertising a narrower public profile), tracked below.

Still open:

- **Probe transport.**  Plain HTTP `GET /node_info`, or an `rpc/2-3` call so the
  probe path exercises the same cross-node machinery the demonstrator
  teaches?
- **Internal-actor / narrow-public mechanism.**  How does n0 run the
  `actor`-profile custodian internally while advertising a narrower public
  contract (per the decision above)?  This is the concrete enabler the
  ceiling decision depends on.
- **Replica vs. live query for the UI.**  The poll reads the stateless
  replica; is there any view (e.g. an admin/debug pane) that should talk to
  the custodian directly via `nodes(From)` for a non-cached snapshot?
