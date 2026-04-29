:- use_module(library(settings)).
:- ['../load.pl'].
:- use_module(shared_db_paths, [
    common_shared_db_path/1,
    node_overlay_shared_db_path/2
]).

:- dynamic start_admin_done/0.

:- initialization(start_admin).

start_admin :-
    start_admin_done,
    !.
start_admin :-
    common_shared_db_path(CommonSharedDBPath),
    node_overlay_shared_db_path(admin, OverlaySharedDBPath),
    set_setting(http:public_host, 'admin.elfenbenstornet.se'),
    set_setting(http:public_port, 443),
    set_setting(http:public_scheme, https),
    node(3054, [
        sandbox(blacklist),
        profile(actor),
        auth(open),
        timeout(10),
        max_inflight_calls(2),
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
            'https://n4.elfenbenstornet.se',
            'https://admin.elfenbenstornet.se'
        ]),
        load_shared_db_file(CommonSharedDBPath),
        load_shared_db_file(OverlaySharedDBPath)
    ]),
    assertz(start_admin_done).

start_admin_forever :-
    start_admin,
    thread_get_message(_).
