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
