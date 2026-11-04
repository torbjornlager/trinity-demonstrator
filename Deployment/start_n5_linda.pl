% Deployment adapter: install owner applications before the Trealla listener.
:- module(n5_linda_start, [start_node/0]).
:- use_module('/app/Deployment/start_node.pl', []).
:- use_module('/app/owner_services/linda_service_trealla.pl', []).

start_node :-
    deployment_start:check_config,
    linda_service_trealla:start_linda_service(_),
    deployment_start:start_node.

% Match N3/N4's owner-installed Docker topology while preserving public PIDs.
:- multifile distribution:hook_websocket_endpoint/2.
distribution:hook_websocket_endpoint('https://n3.elfenbenstornet.se', 'ws://wp_n3:3053/ws').
distribution:hook_websocket_endpoint('https://n4.elfenbenstornet.se', 'ws://wp_n4:3055/ws').
