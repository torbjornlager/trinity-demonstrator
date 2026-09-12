:- ['../load.pl'].
:- use_module(library(plunit)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(socket)).
:- load_files(policy_example:'../examples/actors/22 service-policy.pl', []).

policy_case([service(laptop), cost(700)], permitted).
policy_case([service(laptop), cost(1000)], permitted).
policy_case([service(laptop), cost(1001)], insufficient(policy_gap)).
policy_case([service(restricted), cost(1)], forbidden).
policy_case([service(vpn), cost(10)], conflicting).
policy_case([service(vpn), cost(1000)], conflicting).
policy_case([service(vpn), cost(1001)], forbidden).
policy_case([service(laptop)], insufficient(missing_fields)).
policy_case([service(restricted)], insufficient(missing_fields)).
policy_case([cost(10)], insufficient(missing_fields)).
policy_case([], insufficient(missing_fields)).
policy_case([service(training), cost(500)], insufficient(policy_gap)).

:- begin_tests(service_policy_example).

test(one_assessment_per_request, [forall(policy_case(Fields, Expected))]) :-
    findall(Decision, policy_example:classify(Fields, Decision), Decisions),
    assertion(Decisions == [Expected]).

test(field_order_does_not_change_assessment,
     [forall(policy_case(Fields, Expected))]) :-
    reverse(Fields, Reversed),
    findall(Decision, policy_example:classify(Reversed, Decision), Decisions),
    assertion(Decisions == [Expected]).

test(isobase_runs_drawer_source) :-
    tcp_socket(Socket), tcp_bind(Socket, Port), tcp_close_socket(Socket),
    setup_call_cleanup(
        node(Port, [auth(open), profile(stateless), sandbox(blacklist)]),
        check_public_policy(Port),
        http_stop_server(Port, [])).

:- end_tests(service_policy_example).

check_public_policy(Port) :-
    format(atom(URI), 'http://localhost:~d', [Port]),
    read_file_to_string('examples/actors/22 service-policy.pl', Source, []),
    forall(policy_case(Fields, Expected),
        ( findall(Decision,
              rpc(URI, classify(Fields, Decision), [src_text(Source)]),
              Decisions),
          assertion(Decisions == [Expected]) )).
