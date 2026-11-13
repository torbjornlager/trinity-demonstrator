:- use_module('../Deployment/domain_origins').
:- use_module(library(plunit)).
:- meta_predicate with_endpoint_env(+,0).
with_endpoint_env(Value,Goal) :-
    setup_call_cleanup(
      ((getenv('WP_N2_N4_RPC_ENDPOINT',Old)->Saved=some(Old);Saved=none),
       (Value==absent->unsetenv('WP_N2_N4_RPC_ENDPOINT');setenv('WP_N2_N4_RPC_ENDPOINT',Value))),
      Goal,
      (Saved=some(Previous)->setenv('WP_N2_N4_RPC_ENDPOINT',Previous);unsetenv('WP_N2_N4_RPC_ENDPOINT'))).
:- begin_tests(n2_rpc_configuration).
test(local_development_unchanged,[forall(member(Value,[absent,'']))]) :-
    with_endpoint_env(Value,demonstrator_n2_rpc_endpoints([])).
test(owner_can_configure_origin,[forall(member(URI,['http://wp_n4:3055','https://private.example/']))]) :-
    with_endpoint_env(URI,demonstrator_n2_rpc_endpoints(['https://n4.elfenbenstornet.se'-URI])).
test(invalid_configuration_rejected_without_disclosing_value,
     [forall(member(URI,['file:///tmp/x','http://user:secret@host','http://host/path',
                        'http://host?token=secret','http://host#x','http://host:bad','http://host:0','http://']))]) :-
    with_endpoint_env(URI,
      catch((demonstrator_n2_rpc_endpoints(_),throw(unexpected_success)),
            error(domain_error(rpc_endpoint_configuration,'WP_N2_N4_RPC_ENDPOINT'),
                  demonstrator_n2_rpc_endpoints/1),true)).
:- end_tests(n2_rpc_configuration).
