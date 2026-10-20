:- module(test_zero_poll_accounting, []).
:- use_module('../../../prolog/web_prolog/node.pl', []).
:- use_module('../../../prolog/web_prolog/actors.pl').
:- use_module('../../../prolog/web_prolog/node_lifetime.pl', [with_owner_context/4]).
:- use_module(library(plunit)).

probe :-
    self(Self),node_lifetime:actor_key(Self,Key),
    send(Self,first),send(Self,pick),send(Self,last),
    node_lifetime:mailbox_count(Key,3),
    receive({pick -> true},[timeout(0),on_timeout(fail)]),
    node_lifetime:mailbox_count(Key,2),
    % Rejected messages move to deferred storage without freeing quota.
    receive({missing -> fail},[timeout(0.0),on_timeout(Outcome=empty)]),
    Outcome==empty,node_lifetime:mailbox_count(Key,2),
    receive({first -> true},[timeout(0),on_timeout(fail)]),
    node_lifetime:mailbox_count(Key,1),
    receive({last -> true},[timeout(0),on_timeout(fail)]),
    node_lifetime:mailbox_count(Key,0),
    make_ref(Ref),make_ref(Other),
    send(Self,unrelated),send(Self,down(dummy,Ref,done)),
    send(Self,down(dummy,Other,keep)),
    node_lifetime:mailbox_count(Key,3),
    demonitor(Ref,[flush]),node_lifetime:mailbox_count(Key,2),
    receive({unrelated -> true},[timeout(0),on_timeout(fail)]),
    receive({down(dummy,Other,keep) -> true},[timeout(0),on_timeout(fail)]),
    node_lifetime:mailbox_count(Key,0).

run_probe(Parent,Ref) :-
    catch((probe -> Result=ok;Result=failed),Error,Result=error(Error)),
    send(Parent,zero_poll_result(Ref,Result)).

:- begin_tests(zero_poll_accounting).

test(queued_deferred_and_flushed_messages_are_counted_once) :-
    self(Self),make_ref(Ref),
    setup_call_cleanup(
      with_owner_context(principal{id:"zero-poll-owner",capabilities:[execute],unknown:false},
        zero_poll_probe,local,spawn(test_zero_poll_accounting:run_probe(Self,Ref),Pid,[monitor(true)])),
      (receive({zero_poll_result(Ref,Result) -> true},[timeout(3),on_timeout(fail)]),
       assertion(Result==ok),
       receive({down(Pid,Pid,true) -> true},[timeout(2),on_timeout(fail)])),
      (demonitor(Pid,[flush]),exit(Pid,kill))).

:- end_tests(zero_poll_accounting).
