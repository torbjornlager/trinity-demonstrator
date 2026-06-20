:- module(discovery_hub, [
    start_discovery_hub/1,        % +Port
    start_discovery_hub/2,        % +Port, -RegistryPid
    attach_discovery_hub/1,       % +Port
    attach_discovery_hub/2,       % +Port, -RegistryPid
    stop_discovery_hub/0,
    set_seed/1,                   % +ListOfSeedTerms
    load_seed_file/1,             % +File
    clear_seed/0,
    directory_source_file/1,      % -File
    seed_node/5                   % ?Id, ?Url, ?Description, ?SharedDb, ?Note
]).

/** <module> Discovery hub — the registry custodian (slice 1)

A node whose database holds a live register of the other nodes,
queryable through the same `/call` API every node already speaks
(see docs/DISCOVERY_HUB_PLAN.md).  This is owner-local bootstrap code,
the same shape as examples/services/node_resident_services.pl: it
starts an `actor`-profile node (n0) and runs a single registry service
alongside it.

Slice 1 is probe-only: the custodian holds the records and a 30s
heartbeat; per sweep it fans out one transient prober per node that
fetches `/node_info`, reports the outcome back as a message, and dies.
The custodian folds results in and republishes a generation-buffered
read replica into the node's shared database, where the rules in
discovery_directory.pl turn it back into queryable relations.

  - The custodian (registry_actor/1) never blocks on the network.
  - A node never reports its own liveness; the hub *decides* status by
    probing (discovery_directory.pl derives it at read time).
  - The seed tier (id, url, description, shared_db) is never sourced
    from a node, so a buggy or hostile node cannot rewrite the directory
    entries we chose for it — it can only move profile/auth.

Usage (after `?- [load].`):

    ?- use_module('examples/services/discovery_hub.pl').
    ?- start_discovery_hub(3060).
    ?- rpc('http://localhost:3060', node_record(n0, R)).

Reconfigure the seed before starting with set_seed/1 (handy for tests
that probe locally-started nodes instead of the public deployment).
*/

:- use_module(library(web_prolog)).
:- use_module(library(http/http_open)).
:- use_module(library(http/json)).
:- use_module(library(apply)).
:- use_module(library(lists)).

:- dynamic seed_node/5.
:- dynamic seed_probe_url/2.        % Id, internal probe URL (optional)


                /*******************************
                *           BOOTSTRAP          *
                *******************************/

%!  start_discovery_hub(+Port) is det.
%!  start_discovery_hub(+Port, -RegistryPid) is det.
%
%   Start n0 as an `actor` node serving discovery_directory.pl as its
%   shared database, then spawn and register the registry custodian.
%   If no seed has been configured, install the default public seed.

start_discovery_hub(Port) :-
    start_discovery_hub(Port, _RegistryPid).

start_discovery_hub(Port, RegistryPid) :-
    directory_source_file(File),
    node(Port, [profile(actor), load_shared_db_file(File)]),
    attach_discovery_hub(Port, RegistryPid).

%!  attach_discovery_hub(+Port) is det.
%!  attach_discovery_hub(+Port, -RegistryPid) is det.
%
%   Attach the registry custodian to a node that is *already running*
%   on Port and already serves discovery_directory.pl as its shared
%   database (e.g. one booted by Deployment/start_node.pl with the
%   discovery-hub mode on).  This is the deployment entry point;
%   start_discovery_hub/2 is start-the-node-too convenience for
%   interactive use.

attach_discovery_hub(Port) :-
    attach_discovery_hub(Port, _RegistryPid).

attach_discovery_hub(Port, RegistryPid) :-
    node:with_node_port_context(Port, node:current_shared_db_module(SharedModule)),
    hub_self_url(Port, SelfUrl),
    ensure_seed(SelfUrl),
    findall(Node0, seed_to_node(Node0), Nodes0),
    maplist(localize_probe_url(Port), Nodes0, Nodes),
    State = hub{module:SharedModule, gen:0, nodes:Nodes},
    stop_registry_service,
    spawn(registry_boot(State), RegistryPid, [link(false)]),
    register_service(registry, RegistryPid).

%!  localize_probe_url(+Port, +Node0, -Node) is det.
%
%   The hub cannot in general reach its own advertised public URL from
%   inside itself (a reverse proxy / NAT rarely hairpins), so n0's
%   self-probe must target localhost on the bind port — independent of
%   the public URL it *advertises* in its card.  This keeps the displayed
%   `url` public while making the liveness probe actually succeed.

localize_probe_url(Port, Node0, Node) :-
    (   Node0.id == n0
    ->  format(atom(LocalUrl), 'http://localhost:~w', [Port]),
        Node = Node0.put(probe_url, LocalUrl)
    ;   Node = Node0
    ).

%!  stop_discovery_hub is det.
%
%   Stop the registry custodian and unregister the service.  The node
%   itself (the HTTP server) is left running; stop it with
%   http_stop_server/2 if you want the port back.

stop_discovery_hub :-
    stop_registry_service.

stop_registry_service :-
    (   whereis_service(registry, Pid),
        Pid \== undefined
    ->  catch(exit(Pid, kill), _, true),
        catch(unregister_service(registry), _, true)
    ;   catch(unregister_service(registry), _, true)
    ).

directory_source_file(File) :-
    module_property(discovery_hub, file(Self)),
    file_directory_name(Self, Dir),
    directory_file_path(Dir, 'discovery_directory.pl', File).

hub_self_url(Port, Url) :-
    (   catch(node:with_node_port_context(Port, self_node_url(Url0)), _, fail),
        Url0 \== ''
    ->  Url = Url0
    ;   format(atom(Url), 'http://localhost:~w', [Port])
    ).


                /*******************************
                *             SEED             *
                *******************************/

%!  set_seed(+SeedTerms) is det.
%!  clear_seed is det.
%
%   Replace the curated seed.  Each term is seed_node(Id, Url,
%   Description, SharedDb, Note).  n0 (the hub's own card) is supplied
%   automatically at start if absent, so a seed need only list the
%   peers.

set_seed(SeedTerms) :-
    clear_seed,
    forall(member(Term, SeedTerms), assert_seed_term(Term)).

%!  load_seed_file(+File) is det.
%
%   Replace the seed from a plain Prolog file holding `seed_node/5.`
%   facts and, optionally, `seed_probe_url/2.` facts — the latter give a
%   node an *internal* probe address distinct from its public display
%   URL (e.g. a co-located node reached as `http://n5:3060` over the
%   container network rather than hairpinning to its public name).  n0 is
%   still supplied automatically at start if the file does not name it.

load_seed_file(File) :-
    read_seed_terms(File, Terms),
    clear_seed,
    forall(member(Term, Terms), assert_seed_term(Term)).

read_seed_terms(File, Terms) :-
    setup_call_cleanup(
        open(File, read, Stream),
        read_seed_stream(Stream, Terms),
        close(Stream)).

read_seed_stream(Stream, Terms) :-
    read_term(Stream, Term, []),
    (   Term == end_of_file
    ->  Terms = []
    ;   valid_seed_term(Term)
    ->  Terms = [Term|Rest],
        read_seed_stream(Stream, Rest)
    ;   throw(error(type_error(seed_term, Term), _))
    ).

valid_seed_term(seed_node(_, _, _, _, _)).
valid_seed_term(seed_probe_url(_, _)).

assert_seed_term(seed_node(Id, Url, Desc, SharedDb, Note)) :-
    !,
    assertz(seed_node(Id, Url, Desc, SharedDb, Note)).
assert_seed_term(seed_probe_url(Id, Url)) :-
    !,
    assertz(seed_probe_url(Id, Url)).
assert_seed_term(Term) :-
    throw(error(type_error(seed_term, Term), _)).

clear_seed :-
    retractall(seed_node(_, _, _, _, _)),
    retractall(seed_probe_url(_, _)).

%!  ensure_seed(+SelfUrl) is det.
%
%   If the operator configured no seed, install the default public one.
%   Always make sure n0 itself appears (self-referential and honest,
%   plan §7); if the configured seed already names n0, respect it.

ensure_seed(SelfUrl) :-
    (   seed_node(_, _, _, _, _)
    ->  true
    ;   default_seed
    ),
    (   seed_node(n0, _, _, _, _)
    ->  true
    ;   assertz(seed_node(n0, SelfUrl,
            "The discovery hub.  A RELATION node that publishes the live \c
             register of the other nodes as named query relations over \c
             the stateless /call API.  (It runs an actor internally to \c
             probe them; that surface is not public.)",
            "discovery_directory.pl: the published read replica \c
             (node_record/2 and the node_* query relations).",
            "This is the registry."))
    ).

%!  default_seed is det.
%
%   The author-curated seed lifted from the demonstrator's
%   splashNodeCards.  URLs point at the public deployment; override with
%   set_seed/1 for a local demo or test.

default_seed :-
    assertz(seed_node(n1, 'https://n1.elfenbenstornet.se',
        "The conservative stateless node.  Use it for relational \c
         querying and stateless Prolog execution over the /call API.",
        "Family predicates from the common deployment layer, plus \c
         human(plato), human(aristotle), and deployment_node(n1).",
        "")),
    assertz(seed_node(n2, 'https://n2.elfenbenstornet.se',
        "The semi-stateful HTTP node.  Adds toplevel sessions, private \c
         session databases, incremental loading, and an rpc/2-3 demo.",
        "Common family predicates plus mortal/1, ancestor/2, \c
         descendant/2, human(socrates), and a distributed human/1.",
        "")),
    assertz(seed_node(n3, 'https://n3.elfenbenstornet.se',
        "The fully stateful node.  Adds /ws, direct actor messaging, \c
         node-resident services, and the statechart demonstrator.",
        "Common base + actor-common layer + the n3 overlay, with \c
         registered counter / pubsub_service services.",
        "")),
    assertz(seed_node(n4, 'https://n4.elfenbenstornet.se',
        "A second public ACTOR node for cross-node actor and statechart \c
         demonstrations.  Pair it with n3 for distributed messaging.",
        "Common base + the same actor-common layer as n3, plus an n4 \c
         overlay providing human(plato) / human(aristotle).",
        "")).

%!  seed_to_node(-Node) is nondet.
%
%   Lift a seed term to the in-actor record dict.  The self-reported
%   tier (profile, auth) starts `unknown` and the observed tier starts
%   zeroed; both fill in once the node is probed.

seed_to_node(Node) :-
    seed_node(Id, Url, Desc, SharedDb, Note),
    ( seed_probe_url(Id, ProbeUrl) -> true ; ProbeUrl = Url ),
    Node = node{
        id: Id,
        url: Url,
        probe_url: ProbeUrl,    % internal probe target if seeded, else url;
                                % n0 is further localized (localize_probe_url/3)
        description: Desc,
        shared_db: SharedDb,
        note: Note,
        profile: unknown,
        auth: unknown,
        version: "",
        services: [],
        provides: [],
        self_contained: unknown,
        maintenance: false,
        last_seen: 0,
        last_error: 0,
        latency_ms: 0
    }.


                /*******************************
                *      REGISTRY CUSTODIAN      *
                *******************************/

%!  registry_boot(+State) is det.
%
%   Publish the seed replica (every node `down` until first probed),
%   kick off an immediate sweep, then enter the custodian loop.

registry_boot(State0) :-
    publish_replica(State0, State1),
    do_sweep(State1),
    registry_actor(State1).

%!  registry_actor(+State) is det.
%
%   The custodian: holds the records, folds in probe results, and lets
%   its own receive-timeout drive the 30s sweep.  It does no IO — every
%   network fetch lives in a throwaway prober — so a slow node ties up
%   only its own prober, never the custodian.
%
%   receive/2 does not loop: each path must carry its own continuation
%   by recursing, and the on_timeout goal is the tail (plan §3.2).  The
%   clauses are qualified with this module so that the on_timeout goal
%   and the clause bodies resolve here and not in `actors`.

registry_actor(State0) :-
    receive(discovery_hub:{
        probe_result(Id, Outcome) ->
            apply_probe(Id, Outcome, State0, State1),
            publish_replica(State1, State2),
            registry_actor(State2) ;

        nodes(From) ->
            From ! nodes(State0.nodes),
            registry_actor(State0) ;

        stop ->
            true
    }, [
        timeout(30),
        on_timeout(( do_sweep(State0), registry_actor(State0) ))
    ]).


                /*******************************
                *            PROBING           *
                *******************************/

%!  do_sweep(+State) is det.
%
%   Fan out one transient, unlinked prober per node.  Each fetches
%   /node_info and reports back into the custodian's mailbox, then dies.

do_sweep(State) :-
    self(Me),
    forall(member(Node, State.nodes),
           spawn(probe_one(Node.id, Node.probe_url, Me), _Pid, [link(false)])).

probe_one(Id, Url, Registry) :-
    (   catch(fetch_info(Url, Info, LatencyMs), _, fail)
    ->  Registry ! probe_result(Id, ok(Info, LatencyMs))
    ;   Registry ! probe_result(Id, error)
    ).

%!  fetch_info(+Url, -Info, -LatencyMs) is semidet.
%
%   The one blocking call, isolated in a prober: GET <Url>/node_info as
%   JSON and time it.

fetch_info(Url, Info, LatencyMs) :-
    node_info_url(Url, InfoUrl),
    get_time(T0),
    setup_call_cleanup(
        http_open(InfoUrl, Stream,
                  [ request_header('Accept'='application/json'),
                    timeout(5)
                  ]),
        json_read_dict(Stream, Info0),
        close(Stream)),
    readiness_maintenance(Url, Maintenance),
    Info = Info0.put(maintenance, Maintenance),
    get_time(T1),
    LatencyMs is integer((T1 - T0) * 1000).

node_info_url(Url, InfoUrl) :-
    atom_string(Url, S),
    ( string_concat(Base, "/", S) -> true ; Base = S ),
    atomic_list_concat([Base, '/node_info'], InfoUrl).

readiness_maintenance(Url, Maintenance) :-
    readyz_url(Url, ReadyUrl),
    (   catch(http_status(ReadyUrl, Status), _, fail)
    ->  ( Status =:= 503 -> Maintenance = true ; Maintenance = false )
    ;   Maintenance = false
    ).

readyz_url(Url, ReadyUrl) :-
    atom_string(Url, S),
    ( string_concat(Base, "/", S) -> true ; Base = S ),
    atomic_list_concat([Base, '/readyz'], ReadyUrl).

http_status(URL, Status) :-
    setup_call_cleanup(
        http_open(URL, Stream,
                  [ request_header('Accept'='application/json'),
                    status_code(Status),
                    timeout(5)
                  ]),
        read_string(Stream, _, _),
        close(Stream)).


                /*******************************
                *         FOLD / REPLICA       *
                *******************************/

%!  apply_probe(+Id, +Outcome, +State0, -State) is det.
%
%   ok(Info,L): overwrite the self-reported tier (profile, auth) and
%   stamp the observed tier (last_seen := now, latency_ms := L); leave
%   the seed tier untouched.  error: stamp last_error := now only —
%   crucially *not* last_seen, so aging can notice the node went quiet
%   (plan §3.3).

apply_probe(Id, Outcome, State0, State) :-
    now(Now),
    maplist(update_matching(Id, Outcome, Now), State0.nodes, Nodes),
    State = State0.put(nodes, Nodes).

update_matching(Id, Outcome, Now, Node0, Node) :-
    (   Node0.id == Id
    ->  apply_outcome(Outcome, Now, Node0, Node)
    ;   Node = Node0
    ).

apply_outcome(ok(Info, LatencyMs), Now, Node0, Node) :-
    info_field(profile, Info, Profile),
    info_field(auth, Info, Auth),
    info_list(services, Info, Services),
    info_list(provides, Info, Provides),
    info_bool(self_contained, Info, SelfContained),
    info_bool(maintenance, Info, Maintenance),
    Node = Node0.put(_{
        profile: Profile,
        auth: Auth,
        services: Services,
        provides: Provides,
        self_contained: SelfContained,
        maintenance: Maintenance,
        last_seen: Now,
        latency_ms: LatencyMs
    }).
apply_outcome(error, Now, Node0, Node) :-
    Node = Node0.put(last_error, Now).

info_field(Key, Info, Value) :-
    (   get_dict(Key, Info, Raw)
    ->  to_atom(Raw, Value)
    ;   Value = unknown
    ).

%!  info_list(+Key, +Info, -List) is det.
%
%   Harvest a self-reported capability array (services / provides) from
%   the probed node's /node_info into a list of atoms; absent ⇒ [].
info_list(Key, Info, List) :-
    (   get_dict(Key, Info, Raw),
        is_list(Raw)
    ->  maplist(to_atom, Raw, List)
    ;   List = []
    ).

%!  info_bool(+Key, +Info, -Value) is det.
%
%   Harvest a self-reported boolean (e.g. self_contained) as true/false;
%   absent or unrecognised ⇒ unknown.  json_read_dict may surface JSON
%   booleans as true/false or @(true)/@(false).
info_bool(Key, Info, Value) :-
    (   get_dict(Key, Info, Raw)
    ->  (   ( Raw == true ; Raw == @(true) )  -> Value = true
        ;   ( Raw == false ; Raw == @(false) ) -> Value = false
        ;   Value = unknown
        )
    ;   Value = unknown
    ).

to_atom(A, A) :- atom(A), !.
to_atom(S, A) :- ( atom_string(A, S) -> true ; term_to_atom(A, S) ).

now(Now) :-
    get_time(F),
    Now is integer(F).

%!  publish_replica(+State0, -State) is det.
%
%   Republish the read replica into the shared module behind a
%   generation pointer (plan §3.4).  Build the new generation fully,
%   flip current_gen/1 (asserting the new pointer *before* retracting
%   the old), then GC — but keep Gen-1 intact for any straggling reader
%   that committed to it, so GC is one generation behind and the scheme
%   is lock-free and semantics-independent.

publish_replica(State0, State) :-
    Module = State0.module,
    Gen is State0.gen + 1,
    forall(member(Node, State0.nodes),
           ( published_record(Node, Rec),
             assertz(Module:node_record_gen(Gen, Node.id, Rec)) )),
    findall(P, ( Module:current_gen(P), P \== Gen ), Stale),
    assertz(Module:current_gen(Gen)),
    forall(member(P, Stale), retract(Module:current_gen(P))),
    GcBefore is Gen - 1,
    findall(Old, ( Module:node_record_gen(Old, _, _), Old < GcBefore ), Olds0),
    sort(Olds0, Olds),
    forall(member(Old, Olds), retractall(Module:node_record_gen(Old, _, _))),
    State = State0.put(gen, Gen).

%!  published_record(+Node, -Record) is det.
%
%   The public wire record drops the internal probe_url: it is an
%   addressing detail of how the hub reaches a node, not part of the
%   advertised directory entry.

published_record(Node, Record) :-
    ( del_dict(probe_url, Node, _, Record) -> true ; Record = Node ).
