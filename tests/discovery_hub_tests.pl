/*  Discovery hub tests (docs/DISCOVERY_HUB_PLAN.md, slice 1).

    Two layers:

      - `discovery_status`: the pure read-side status derivation from
        discovery_directory.pl, driven with controlled timestamps so it
        is deterministic (no sleeps).
      - `discovery_integration`: a hub node + a live peer + a dead URL,
        with a bounded wait for the boot sweep to populate the replica.
        Network-timing sensitive, so it is kept out of the tiered gate
        and run on its own.

    Run (from the repo root):

      SWIPL=/Applications/SWI-Prolog.app/Contents/MacOS/swipl
      $SWIPL -q -g "consult('tests/discovery_hub_tests.pl'), \
                    (run -> halt(0) ; halt(1))"
*/

:- prolog_load_context(directory, Dir),
   atom_concat(Dir, '/../prolog', LibDir),
   asserta(user:file_search_path(library, LibDir)).

:- use_module(library(web_prolog)).
:- use_module(library(web_prolog/rpc)).
:- use_module(library(plunit)).
:- use_module(library(http/thread_httpd), [http_stop_server/2]).
:- use_module(library(http/http_open), [http_open/3]).
:- use_module(library(http/json), [json_read_dict/2]).

%  The read side, loaded here so we can drive its dynamic replica facts
%  directly with known timestamps.  A plain (non-module) file's clauses
%  load into `user` regardless of the module/1 option, so the status
%  tests below reference node_record/2 et al. unqualified (i.e. user:).
:- prolog_load_context(directory, Dir),
   atom_concat(Dir, '/../examples/services/discovery_directory.pl', DirFile),
   load_files(DirFile, []).

:- use_module('../examples/services/discovery_hub.pl').

run :-
    run_tests([discovery_status, discovery_integration,
               relation_conjunction, relation_provides_exclusion,
               node_resident_provides,
               dependent_undefined_call, dependent_custom_import]).


                /*******************************
                *       STATUS DERIVATION      *
                *******************************/

%  Build a replica record dict with the given observed timestamps and
%  publish it as the single current generation.
seed_replica(Id, LastSeen, LastError) :-
    retractall(node_record_gen(_, _, _)),
    retractall(current_gen(_)),
    Rec = node{
        id: Id, url: 'http://x', description: "d", shared_db: "s",
        note: "", profile: actor, auth: open, version: "",
        services: [], provides: [],
        last_seen: LastSeen, last_error: LastError, latency_ms: 7
    },
    assertz(node_record_gen(1, Id, Rec)),
    assertz(current_gen(1)).

%  A two-node replica: UpId fresh (→ up), DownId never seen (→ down).
%  Defined in `user` (like seed_replica/3) so its assert/retract hit
%  user:node_record_gen rather than a plunit test module's local copy.
seed_replica_pair(UpId, DownId) :-
    retractall(node_record_gen(_, _, _)),
    retractall(current_gen(_)),
    get_time(F), Now is integer(F),
    base_record(UpId, Now, Up),
    base_record(DownId, 0, Down),
    assertz(node_record_gen(1, UpId, Up)),
    assertz(node_record_gen(1, DownId, Down)),
    assertz(current_gen(1)).

base_record(Id, LastSeen, node{
        id: Id, url: u, description: "", shared_db: "", note: "",
        profile: actor, auth: open, version: "", services: [], provides: [],
        last_seen: LastSeen, last_error: 0, latency_ms: 1
    }).

%  One fresh record with given profile + harvested capabilities (in user,
%  so the assert hits user:node_record_gen, not a plunit module's copy).
seed_record(Id, Profile, Services, Provides) :-
    retractall(node_record_gen(_, _, _)),
    retractall(current_gen(_)),
    get_time(F), Now is integer(F),
    Rec = node{id: Id, url: u, description: "", shared_db: "", note: "",
               profile: Profile, auth: open, version: "",
               services: Services, provides: Provides,
               last_seen: Now, last_error: 0, latency_ms: 1},
    assertz(node_record_gen(1, Id, Rec)),
    assertz(current_gen(1)).

%  Two fresh actor/up records with the given provides lists (in user).
seed_pair_provides(Id1, Provides1, Id2, Provides2) :-
    retractall(node_record_gen(_, _, _)),
    retractall(current_gen(_)),
    get_time(F), Now is integer(F),
    R1 = node{id:Id1, url:u, description:"", shared_db:"", note:"", profile:actor,
              auth:open, version:"", services:[], provides:Provides1,
              last_seen:Now, last_error:0, latency_ms:1},
    R2 = node{id:Id2, url:u, description:"", shared_db:"", note:"", profile:actor,
              auth:open, version:"", services:[], provides:Provides2,
              last_seen:Now, last_error:0, latency_ms:1},
    assertz(node_record_gen(1, Id1, R1)),
    assertz(node_record_gen(1, Id2, R2)),
    assertz(current_gen(1)).

:- begin_tests(discovery_status).

test(fresh_success_is_up, S == up) :-
    get_time(F), Now is integer(F),
    seed_replica(n1, Now, 0),
    node_status(n1, S).

test(fresh_but_newer_error_is_unreachable, S == unreachable) :-
    get_time(F), Now is integer(F),
    Err is Now + 1,                        % error strictly newer than seen
    seed_replica(n1, Now, Err),
    node_status(n1, S).

test(stale_success_is_down, S == down) :-
    get_time(F), Now is integer(F),
    Old is Now - 100,                      % past the 75s TTL
    seed_replica(n1, Old, 0),
    node_status(n1, S).

test(never_seen_is_down, S == down) :-
    seed_replica(n1, 0, 0),
    node_status(n1, S).

test(old_error_does_not_supersede_fresh_success, S == up) :-
    get_time(F), Now is integer(F),
    OldErr is Now - 10,                    % error older than the latest seen
    seed_replica(n1, Now, OldErr),
    node_status(n1, S).

test(record_carries_derived_status_and_seed_fields) :-
    get_time(F), Now is integer(F),
    seed_replica(n2, Now, 0),
    node_record(n2, R),
    assertion(get_dict(status, R, up)),
    assertion(get_dict(url, R, 'http://x')),
    assertion(get_dict(latency_ms, R, 7)).

test(query_relations_filter, Ids == [n1]) :-
    seed_replica_pair(n1, n2),
    findall(N, (node_profile(N, actor), node_status(N, up)), Ids).

test(directory_row_carries_status_and_seed_fields,
     [St, Url] == [up, 'http://x']) :-
    get_time(F), Now is integer(F),
    seed_replica(n1, Now, 0),
    node_directory_row(n1, St, _Pr, _Au, _La, _Se, Url, _Desc, _Note).

test(node_service_enumerates_harvested_services, Ss == [counter, pubsub_service]) :-
    seed_record(n1, actor, [counter, pubsub_service], []),
    findall(S, node_service(n1, S), Ss).

test(node_provides_enumerates_harvested_predicates, Ps == ['human/1', 'mortal/1']) :-
    seed_record(n1, actor, [], ['human/1', 'mortal/1']),
    findall(P, node_provides(n1, P), Ps).

test(profile_at_least_respects_the_lattice) :-
    seed_record(n2, isotope, [], []),
    assertion(node_profile_at_least(n2, isobase)),   % isotope >= isobase
    assertion(node_profile_at_least(n2, isotope)),
    assertion(\+ node_profile_at_least(n2, actor)).  % isotope < actor

test(capability_query_composes_on_the_replica, Ids == [n1]) :-
    %  the discovery payoff as a single conjunctive query over the replica
    seed_pair_provides(n1, ['human/1'], n2, ['mortal/1']),
    findall(N, (node_profile_at_least(N, actor), node_status(N, up),
                node_provides(N, 'human/1')), Ids).

%  n0 advertises its (possibly public) URL but is probed via localhost,
%  so the self-probe succeeds even when the public name does not hairpin.
test(self_probe_targets_localhost_not_public_url,
     [Url, ProbeUrl] == ['https://hub.example.com', 'http://localhost:3060']) :-
    N0 = node{id:n0, url:'https://hub.example.com', probe_url:'https://hub.example.com',
              description:"", shared_db:"", note:"", profile:unknown, auth:unknown,
              version:"", services:[], provides:[], last_seen:0, last_error:0, latency_ms:0},
    discovery_hub:localize_probe_url(3060, N0, Node),
    get_dict(url, Node, Url),
    get_dict(probe_url, Node, ProbeUrl).

test(peer_probe_url_is_left_public, ProbeUrl == 'https://n3.example.com') :-
    N3 = node{id:n3, url:'https://n3.example.com', probe_url:'https://n3.example.com',
              description:"", shared_db:"", note:"", profile:unknown, auth:unknown,
              version:"", services:[], provides:[], last_seen:0, last_error:0, latency_ms:0},
    discovery_hub:localize_probe_url(3060, N3, Node),
    get_dict(probe_url, Node, ProbeUrl).

%  A seed_probe_url/2 gives a node an internal probe target while its
%  public display url is unchanged (co-located nodes, e.g. http://n5:3060).
test(seed_probe_url_overrides_probe_target,
     [Url, ProbeUrl] == ['https://n5.example.com', 'http://n5:3060']) :-
    setup_call_cleanup(
        ( discovery_hub:clear_seed,
          discovery_hub:assertz(seed_node(n5, 'https://n5.example.com', "d", "s", "")),
          discovery_hub:assertz(seed_probe_url(n5, 'http://n5:3060')) ),
        ( discovery_hub:seed_to_node(Node),
          get_dict(url, Node, Url),
          get_dict(probe_url, Node, ProbeUrl) ),
        discovery_hub:clear_seed).

test(seed_without_probe_url_falls_back_to_display_url, ProbeUrl == 'https://n2.example.com') :-
    setup_call_cleanup(
        ( discovery_hub:clear_seed,
          discovery_hub:assertz(seed_node(n2, 'https://n2.example.com', "d", "s", "")) ),
        ( discovery_hub:seed_to_node(Node),
          get_dict(probe_url, Node, ProbeUrl) ),
        discovery_hub:clear_seed).

test(published_record_drops_internal_probe_url) :-
    N = node{id:n0, url:u, probe_url:'http://localhost:3060', description:"",
             shared_db:"", note:"", profile:actor, auth:open, version:"",
             services:[], provides:[], last_seen:1, last_error:0, latency_ms:1},
    discovery_hub:published_record(N, Rec),
    assertion(\+ get_dict(probe_url, Rec, _)),
    assertion(get_dict(url, Rec, u)).

%  node_self_contained reads the harvested portability flag, defaulting
%  to `unknown` for a record that predates the field (or is unprobed).
test(self_contained_defaults_unknown, V == unknown) :-
    seed_replica(scn, 100, 0),          % seed_replica/3 sets no self_contained
    node_self_contained(scn, V).

test(self_contained_read_from_record, V == false) :-
    retractall(user:node_record_gen(_, _, _)),
    retractall(user:current_gen(_)),
    Rec = node{id:scr, url:u, description:"", shared_db:"", note:"",
               profile:actor, auth:open, version:"", services:[], provides:[],
               self_contained:false,
               last_seen:100, last_error:0, latency_ms:0},
    assertz(user:node_record_gen(1, scr, Rec)),
    assertz(user:current_gen(1)),
    node_self_contained(scr, V).

:- end_tests(discovery_status).


                /*******************************
                *         INTEGRATION          *
                *******************************/

%  Bounded poll: succeed as soon as Goal does, or fail after ~Tries.
wait_until(_, 0) :- !, fail.
wait_until(Goal, Tries) :-
    ( call(Goal) -> true ; sleep(0.2), T1 is Tries - 1, wait_until(Goal, T1) ).

hub_port(3970).
peer_port(3971).

integration_setup :-
    peer_port(Peer),
    node(Peer, [profile(isobase)]),
    set_seed([
        seed_node(n1, 'http://localhost:3971', "live peer", "peer db", ""),
        seed_node(n2, 'http://localhost:3999', "dead", "none", "")
    ]),
    hub_port(Hub),
    start_discovery_hub(Hub).

integration_cleanup :-
    catch(stop_discovery_hub, _, true),
    hub_port(Hub), peer_port(Peer),
    catch(http_stop_server(Hub, []), _, true),
    catch(http_stop_server(Peer, []), _, true),
    clear_seed.

:- begin_tests(discovery_integration,
               [ setup(integration_setup),
                 cleanup(integration_cleanup) ]).

test(live_peer_probed_up, [LiveStatus, LiveProfile] == [up, isobase]) :-
    hub_url(Hub),
    wait_until(rpc(Hub, node_status(n1, up)), 25),
    rpc(Hub, node_status(n1, LiveStatus)),
    rpc(Hub, node_profile(n1, LiveProfile)).

test(dead_node_is_down, S == down) :-
    hub_url(Hub),
    rpc(Hub, node_status(n2, S)).

test(seed_tier_preserved_through_probe, Url == 'http://localhost:3971') :-
    hub_url(Hub),
    rpc(Hub, node_record(n1, R)),
    get_dict(url, R, Url).               % seed url, not overwritten by probe

test(hub_appears_in_its_own_directory, S == up) :-
    hub_url(Hub),
    wait_until(rpc(Hub, node_status(n0, up)), 25),
    rpc(Hub, node_status(n0, S)).

%  End-to-end harvest: the live peer runs the default (self-contained)
%  shared DB, so once probed the hub's replica reports it self-contained.
test(live_peer_self_contained_harvested, V == true) :-
    hub_url(Hub),
    wait_until(rpc(Hub, node_status(n1, up)), 25),
    rpc(Hub, node_self_contained(n1, V)).

:- end_tests(discovery_integration).

hub_url(Url) :-
    hub_port(Port),
    format(atom(Url), 'http://localhost:~w', [Port]).


                /*******************************
                *    RELATION CONJUNCTIONS     *
                *******************************/

%  A RELATION node serves a conjunction of *advertised* relations (a
%  join), but still refuses arbitrary goals and non-conjunction control
%  constructs.  See DEVIATIONS.md (2026-06-16).

rel_port(3973).

rel_url(Url) :- rel_port(P), format(atom(Url), 'http://localhost:~w', [P]).

:- dynamic rel_db_file/1.

relation_setup :-
    tmp_file_stream(text, File, S),
    write(S, "relation_filter(a(_)).\nrelation_filter(b(_)).\n\c
              a(1).\na(2).\nb(2).\n"),
    close(S),
    retractall(rel_db_file(_)),
    assertz(rel_db_file(File)),
    rel_port(P),
    node(P, [profile(relation), load_shared_db_file(File)]).

relation_cleanup :-
    rel_port(P),
    catch(http_stop_server(P, []), _, true),
    ( rel_db_file(F) -> catch(delete_file(F), _, true) ; true ),
    retractall(rel_db_file(_)).

:- begin_tests(relation_conjunction,
               [ setup(relation_setup), cleanup(relation_cleanup) ]).

test(single_advertised_relation_ok, Xs == [1, 2]) :-
    rel_url(U),
    findall(X, rpc(U, a(X)), Xs).

test(conjunction_of_advertised_relations_joins, Xs == [2]) :-
    rel_url(U),
    findall(X, rpc(U, (a(X), b(X))), Xs).

test(arbitrary_predicate_in_conjunction_refused) :-
    rel_url(U),
    catch(rpc(U, (a(X), succ_or_zero(X))), E, true),
    assertion(nonvar(E)).

test(disjunction_refused) :-
    rel_url(U),
    catch(( rpc(U, (a(X) ; b(X))), X = _ ), E, true),
    assertion(nonvar(E)).

test(bare_arbitrary_goal_refused) :-
    rel_url(U),
    catch(rpc(U, succ_or_zero(_)), E, true),
    assertion(nonvar(E)).

:- end_tests(relation_conjunction).


%  When a RELATION node advertises by parsing shared-DB clause heads (no
%  explicit relation_filter), `provides/1` is excluded — it is an
%  owner-curated capability list for /node_info, not a queryable relation.

relp_port(3974).
relp_url(Url) :- relp_port(P), format(atom(Url), 'http://localhost:~w', [P]).

:- dynamic relp_db_file/1.

relation_provides_setup :-
    tmp_file_stream(text, File, S),
    %  seen/1 has a variable head, so its advertised pattern is general
    %  (source-parsed fact heads keep their constants — a separate quirk).
    write(S, "provides(secret/1).\nvisible(1).\nvisible(2).\nseen(X) :- visible(X).\n"),
    close(S),
    retractall(relp_db_file(_)),
    assertz(relp_db_file(File)),
    relp_port(P),
    node(P, [profile(relation), load_shared_db_file(File)]).

relation_provides_cleanup :-
    relp_port(P),
    catch(http_stop_server(P, []), _, true),
    ( relp_db_file(F) -> catch(delete_file(F), _, true) ; true ),
    retractall(relp_db_file(_)).

:- begin_tests(relation_provides_exclusion,
               [ setup(relation_provides_setup), cleanup(relation_provides_cleanup) ]).

test(source_parsed_relation_is_served, Xs == [1, 2]) :-
    relp_url(U),
    findall(X, rpc(U, seen(X)), Xs).

test(provides_is_not_an_advertised_relation) :-
    relp_url(U),
    catch(rpc(U, provides(_)), E, true),
    assertion(nonvar(E)).

:- end_tests(relation_provides_exclusion).


%  /node_info's `provides` is derived from the shared DB itself (no
%  hand-curated provides/1 list): the node-resident predicates the DB
%  defines OR imports via use_module/2, with the I/O prelude, the actor
%  API, SWI built-ins, and the control facts (provides/1, relation_filter/1)
%  subtracted.

nrp_port(3975).
nrp_url(Url) :- nrp_port(P), format(atom(Url), 'http://localhost:~w', [P]).

:- dynamic nrp_db_file/1.

node_resident_provides_setup :-
    tmp_file_stream(text, File, S),
    write(S, ":- use_module(library(lists), [last/2]).\n\c
              local_fact(1).\n\c
              local_rule(X) :- local_fact(X).\n\c
              provides(ignored/9).\n"),
    close(S),
    retractall(nrp_db_file(_)),
    assertz(nrp_db_file(File)),
    nrp_port(P),
    node(P, [profile(isobase), load_shared_db_file(File)]).

node_resident_provides_cleanup :-
    nrp_port(P),
    catch(http_stop_server(P, []), _, true),
    ( nrp_db_file(F) -> catch(delete_file(F), _, true) ; true ),
    retractall(nrp_db_file(_)).

node_info_at(Port, Dict) :-
    format(atom(InfoURL), 'http://localhost:~w/node_info', [Port]),
    setup_call_cleanup(
        http_open(InfoURL, Stream, [request_header('Accept'='application/json')]),
        json_read_dict(Stream, Dict),
        close(Stream)).

fetch_provides(Provides) :-
    nrp_port(P),
    node_info_at(P, Dict),
    Provides = Dict.provides.

%  json_read_dict may surface JSON booleans as true/false or @(true)/@(false).
dh_truthy(true).   dh_truthy(@(true)).
dh_falsy(false).   dh_falsy(@(false)).

:- begin_tests(node_resident_provides,
               [ setup(node_resident_provides_setup),
                 cleanup(node_resident_provides_cleanup) ]).

test(includes_locally_defined) :-
    fetch_provides(P),
    assertion(memberchk("local_fact/1", P)),
    assertion(memberchk("local_rule/1", P)).

test(includes_use_module_imports) :-
    fetch_provides(P),
    assertion(memberchk("last/2", P)).

test(excludes_control_facts) :-
    fetch_provides(P),
    assertion(\+ memberchk("provides/1", P)).

test(excludes_io_prelude_and_builtins) :-
    fetch_provides(P),
    assertion(\+ memberchk("write/1", P)),
    assertion(\+ memberchk("nl/0", P)),
    assertion(\+ memberchk("atom/1", P)).

%  A library import (use_module(library(lists))) is universally
%  resolvable, so a DB using only locals + libraries stays self-contained.
test(self_contained_with_library_import) :-
    nrp_port(P),
    node_info_at(P, Dict),
    assertion(dh_truthy(Dict.self_contained)).

:- end_tests(node_resident_provides).


%  self_contained = false when the shared DB calls a predicate that is
%  undefined here (the manuscript's `philosopher/1` case): copy this DB to
%  another node and it would not work.

dep_undef_port(3976).

:- dynamic dep_undef_file/1.

dependent_undefined_setup :-
    tmp_file_stream(text, File, S),
    write(S, "mortal(X) :- human(X).\n\c
              human(socrates).\n\c
              human(X) :- philosopher(X).\n"),
    close(S),
    retractall(dep_undef_file(_)),
    assertz(dep_undef_file(File)),
    dep_undef_port(P),
    node(P, [profile(isobase), load_shared_db_file(File)]).

dependent_undefined_cleanup :-
    dep_undef_port(P),
    catch(http_stop_server(P, []), _, true),
    ( dep_undef_file(F) -> catch(delete_file(F), _, true) ; true ),
    retractall(dep_undef_file(_)).

:- begin_tests(dependent_undefined_call,
               [ setup(dependent_undefined_setup),
                 cleanup(dependent_undefined_cleanup) ]).

test(undefined_call_is_dependent) :-
    dep_undef_port(P),
    node_info_at(P, Dict),
    assertion(dh_falsy(Dict.self_contained)).

:- end_tests(dependent_undefined_call).


%  self_contained = false when the DB imports from a custom (non-library)
%  module: that module would not travel with the DB.

dep_cust_port(3977).

:- dynamic dep_cust_file/1.
:- dynamic dep_cust_mod_file/1.

dependent_custom_import_setup :-
    tmp_file(custommod, Base),
    atom_concat(Base, '.pl', ModFile),
    setup_call_cleanup(
        open(ModFile, write, MS),
        format(MS, ":- module(custommod, [philosopher/1]).~nphilosopher(plato).~n", []),
        close(MS)),
    tmp_file_stream(text, DbFile, DS),
    format(DS, ":- use_module('~w').~nmortal(X) :- philosopher(X).~n", [ModFile]),
    close(DS),
    retractall(dep_cust_file(_)),
    retractall(dep_cust_mod_file(_)),
    assertz(dep_cust_file(DbFile)),
    assertz(dep_cust_mod_file(ModFile)),
    dep_cust_port(P),
    node(P, [profile(isobase), load_shared_db_file(DbFile)]).

dependent_custom_import_cleanup :-
    dep_cust_port(P),
    catch(http_stop_server(P, []), _, true),
    ( dep_cust_file(F) -> catch(delete_file(F), _, true) ; true ),
    ( dep_cust_mod_file(M) -> catch(delete_file(M), _, true) ; true ),
    retractall(dep_cust_file(_)),
    retractall(dep_cust_mod_file(_)).

:- begin_tests(dependent_custom_import,
               [ setup(dependent_custom_import_setup),
                 cleanup(dependent_custom_import_cleanup) ]).

test(custom_import_is_dependent) :-
    dep_cust_port(P),
    node_info_at(P, Dict),
    assertion(dh_falsy(Dict.self_contained)).

:- end_tests(dependent_custom_import).
