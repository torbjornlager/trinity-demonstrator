:- use_module(library(settings)).
:- ['../load.pl'].
:- use_module(shared_db_paths, [
    common_shared_db_path/1,
    node_overlay_shared_db_path/2
]).

:- dynamic start_n1_done/0.

:- initialization(start_n1).

start_n1 :-
    start_n1_done,
    !.
start_n1 :-
    common_shared_db_path(CommonSharedDBPath),
    node_overlay_shared_db_path(n1, OverlaySharedDBPath),
    set_setting(http:public_host, 'n1.elfenbenstornet.se'),
    set_setting(http:public_port, 443),
    set_setting(http:public_scheme, https),
    node(3051, [
        sandbox(blacklist),
        profile(isobase),
        auth(open),
        timeout(2),
        max_inflight_calls(2),
        max_sessions_per_principal(16),
        max_ws_actors_per_principal(2),
        max_term_text_bytes(16384),
        max_load_text_bytes(65536),
        rate_window_seconds(60),
        max_call_requests_per_window(60),
        max_session_spawns_per_window(10),
        max_ws_commands_per_window(60),
        tutorial_sections([local_isobase, movie_database]),
        load_uri_allowed_origins([
            'https://n1.elfenbenstornet.se',
            'https://n2.elfenbenstornet.se',
            'https://n3.elfenbenstornet.se',
            'https://n4.elfenbenstornet.se'
        ]),
        load_shared_db_file(CommonSharedDBPath),
        load_shared_db_file(OverlaySharedDBPath)
    ]),
    assertz(start_n1_done).

start_n1_forever :-
    start_n1,
    thread_get_message(_).
