:- use_module(library(settings)).
:- use_module(domain_origins, [demonstrator_domain_origins/1, demonstrator_transport_options/1,
                             demonstrator_n2_rpc_endpoints/1]).
:- ['../load.pl'].
:- use_module(library(web_prolog/node_runtime_state), [
    with_node_port_context/2, update_current_node_runtime/1
]).
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
    set_setting(node_http_identity:anonymous_visitors, true),
    demonstrator_domain_origins(DomainOrigins),
    demonstrator_transport_options(PeerOptions),
    demonstrator_n2_rpc_endpoints(Endpoints),
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
        tutorial_sections([all]),
        load_uri_allowed_origins(DomainOrigins),
        load_shared_db_file(CommonSharedDBPath),
        load_shared_db_file(OverlaySharedDBPath) | PeerOptions
    ]),
    % The shared human/1 clause still identifies the public N4 peer. Calls
    % within this Compose deployment need not leave its private network and
    % re-enter through the external HTTPS ingress to reach that same node.
    with_node_port_context(3052,
        update_current_node_runtime(_{rpc_endpoint_overrides:Endpoints})),
    assertz(start_n2_done).

start_n2_forever :-
    start_n2,
    thread_get_message(_).
