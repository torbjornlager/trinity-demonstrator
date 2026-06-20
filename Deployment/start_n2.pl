:- use_module(library(settings)).
:- ['../load.pl'].
:- use_module(shared_db_paths, [
    common_shared_db_path/1,
    node_overlay_shared_db_path/2
]).

:- dynamic start_n2_done/0.

:- initialization(start_n2).

start_n2 :-
    start_n2_done,
    !.
start_n2 :-
    common_shared_db_path(CommonSharedDBPath),
    node_overlay_shared_db_path(n2, OverlaySharedDBPath),
    set_setting(http:public_host, 'n2.elfenbenstornet.se'),
    set_setting(http:public_port, 443),
    set_setting(http:public_scheme, https),
    node(3052, [
        sandbox(blacklist),
        profile(isotope),
        auth(open),
        timeout(4),
        max_inflight_calls(3),
        max_sessions_per_principal(16),
        max_ws_actors_per_principal(4),
        max_term_text_bytes(24576),
        max_load_text_bytes(131072),
        rate_window_seconds(60),
        max_call_requests_per_window(120),
        max_session_spawns_per_window(20),
        max_ws_commands_per_window(200),
        tutorial_sections([dcg, distributed_isobase, local_isotope,
                           semantic_web]),
        load_uri_allowed_origins([
            'https://n1.elfenbenstornet.se',
            'https://n2.elfenbenstornet.se',
            'https://n3.elfenbenstornet.se',
            'https://n4.elfenbenstornet.se'
        ]),
        load_shared_db_file(CommonSharedDBPath),
        load_shared_db_file(OverlaySharedDBPath)
    ]),
    assertz(start_n2_done).

start_n2_forever :-
    start_n2,
    thread_get_message(_).
