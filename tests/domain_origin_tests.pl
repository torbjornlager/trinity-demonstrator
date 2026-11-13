:- ['../load.pl'].
:- use_module('../Deployment/domain_origins').
:- use_module(library(web_prolog/node_runtime_state)).
:- use_module(library(web_prolog/node_sandbox)).
:- use_module(library(settings)).
:- use_module(library(plunit)).

:- meta_predicate with_domain_policy(0).
with_domain_policy(Goal) :-
    demonstrator_domain_origins(Origins),
    setup_call_cleanup(
        ( setting(node:sandbox, Saved), set_setting(node:sandbox, blacklist),
          register_node_runtime(47881, _{load_uri_allowed_origins:Origins}) ),
        with_node_port_context(47881, Goal),
        ( set_setting(node:sandbox, Saved),
          retractall(node_runtime_state:node_runtime(47881,_)) )).

:- begin_tests(domain_origins).
test(all_current_nodes_admit_spawn_options,
     [forall(between(0,7,N))]) :-
    format(atom(URL),'https://n~d.elfenbenstornet.se',[N]),
    with_domain_policy(sandbox_check_spawn_options(actor,[node(URL)])).
test(external_origin_rejected,
     [throws(error(permission_error(option,sandboxed,_),_))]) :-
    with_domain_policy(sandbox_check_spawn_options(actor,[node('https://example.org')])).
test(suffix_lookalike_rejected,
     [throws(error(permission_error(option,sandboxed,_),_))]) :-
    with_domain_policy(sandbox_check_spawn_options(actor,[node('https://n5.elfenbenstornet.se.example.org')])).
test(wrong_port_rejected,
     [throws(error(permission_error(option,sandboxed,_),_))]) :-
    with_domain_policy(sandbox_check_spawn_options(actor,[node('https://n5.elfenbenstornet.se:444')])).
:- end_tests(domain_origins).

:- begin_tests(domain_peer_credentials).
test(absent_file_keeps_default,
     [setup((getenv('WP_PEER_TRANSPORT_TOKENS_FILE',Old)->Saved=some(Old);Saved=none)),
      cleanup(restore_peer_env(Saved))]) :-
    unsetenv('WP_PEER_TRANSPORT_TOKENS_FILE'),
    demonstrator_transport_options([]).
test(owner_file_becomes_node_option,
     [setup((getenv('WP_PEER_TRANSPORT_TOKENS_FILE',Old)->Saved=some(Old);Saved=none)),
      cleanup(restore_peer_env(Saved))]) :-
    setup_call_cleanup(tmp_file_stream(text,File,Stream),
      ( write(Stream,"['https://n7.elfenbenstornet.se'-'synthetic-peer-token-0000000000'].\n"),close(Stream),
        setenv('WP_PEER_TRANSPORT_TOKENS_FILE',File),
        demonstrator_transport_options([peer_transport_tokens(Pairs)]),
        assertion(Pairs==['https://n7.elfenbenstornet.se'-'synthetic-peer-token-0000000000']) ),
      delete_file(File)).
test(malformed_file_error_does_not_disclose_token,
     [setup((getenv('WP_PEER_TRANSPORT_TOKENS_FILE',Old)->Saved=some(Old);Saved=none)),
      cleanup(restore_peer_env(Saved))]) :-
    setup_call_cleanup(tmp_file_stream(text,File,Stream),
      ( write(Stream,"['https://example.org'-'synthetic-peer-token-0000000000'].\n"),close(Stream),
        setenv('WP_PEER_TRANSPORT_TOKENS_FILE',File),
        catch(demonstrator_transport_options(_),Error,true),
        assertion(Error==error(domain_error(peer_transport_configuration,File),demonstrator_transport_options/1)) ),
      delete_file(File)).
restore_peer_env(none) :- unsetenv('WP_PEER_TRANSPORT_TOKENS_FILE').
restore_peer_env(some(Value)) :- setenv('WP_PEER_TRANSPORT_TOKENS_FILE',Value).
:- end_tests(domain_peer_credentials).
