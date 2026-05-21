:- use_module(library(settings)).
:- ['../load.pl'].
:- use_module(shared_db_paths, [
    common_shared_db_path/1,
    actor_common_shared_db_path/1,
    node_overlay_shared_db_path/2
]).
:- use_module('../actor.pl', [
    whereis_service/2
]).
:- use_module('../examples/services/node_resident_services.pl', [
    start_example_services/2
]).
:- use_module('../node_runtime_state.pl', [
    with_node_port_context/2,
    update_current_node_runtime/1
]).

:- dynamic start_n3_done/0.

:- initialization(start_n3).

start_n3 :-
    start_n3_done,
    !.
start_n3 :-
    common_shared_db_path(CommonSharedDBPath),
    actor_common_shared_db_path(ActorCommonSharedDBPath),
    node_overlay_shared_db_path(n3, OverlaySharedDBPath),
    set_setting(http:public_host, 'n3.elfenbenstornet.se'),
    set_setting(http:public_port, 443),
    set_setting(http:public_scheme, https),
    node(3053, [
        sandbox(blacklist),
        profile(actor),
        auth(open),
        timeout(1),
        max_inflight_calls(3),
        max_sessions_per_principal(16),
        max_ws_actors_per_principal(8),
        max_term_text_bytes(32768),
        max_load_text_bytes(131072),
        rate_window_seconds(60),
        max_call_requests_per_window(120),
        max_session_spawns_per_window(30),
        max_ws_commands_per_window(400),
        load_uri_allowed_origins([
            'https://n1.elfenbenstornet.se',
            'https://n2.elfenbenstornet.se',
            'https://n3.elfenbenstornet.se',
            'https://n4.elfenbenstornet.se'
        ]),
        load_shared_db_file(CommonSharedDBPath),
        load_shared_db_file(ActorCommonSharedDBPath),
        load_shared_db_file(OverlaySharedDBPath)
    ]),
    with_node_port_context(3053,
                           update_current_node_runtime(_{
                               ws_endpoint_overrides:[
                                   'https://n3.elfenbenstornet.se'-'ws://wp_n3:3053/ws',
                                   'https://n4.elfenbenstornet.se'-'ws://wp_n4:3055/ws'
                               ]
                           })),
    start_n3_service_bootstrap,
    assertz(start_n3_done).

start_n3_forever :-
    start_n3,
    thread_get_message(_).

start_n3_service_bootstrap :-
    thread_create(
        catch(
            with_node_port_context(3053, ensure_example_services_started),
            Error,
            print_message(error, Error)
        ),
        _,
        [detached(true)]
    ).

ensure_example_services_started :-
    ensure_example_services_started(20).

ensure_example_services_started(0) :-
    throw(error(resource_error(node_resident_services),
                context(start_n3/0,
                        'unable to register counter and pubsub_service on n3'))).
ensure_example_services_started(AttemptsLeft) :-
    start_example_services(_CounterPid, _PubSubPid),
    (   example_services_ready
    ->  true
    ;   sleep(0.05),
        NextAttemptsLeft is AttemptsLeft - 1,
        ensure_example_services_started(NextAttemptsLeft)
    ).

example_services_ready :-
    whereis_service(counter, CounterPid),
    CounterPid \== undefined,
    whereis_service(pubsub_service, PubSubPid),
    PubSubPid \== undefined.
