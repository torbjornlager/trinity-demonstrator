:- module(test_supervisor_restart, []).
:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/supervisor_actor.pl').
:- use_module('../../prolog/web_prolog/supervisor_startup.pl', []).
:- use_module('../../prolog/web_prolog/server_actor.pl').
:- use_module(library(plunit)).
:- use_module(library(gensym)).

:- dynamic attempts/2, identities/3, failure/2, observer/1, stop_fault/2, monitor_failure/2.
:- multifile actors:hook_check_send/2, actors:hook_check_monitor/1.
actors:hook_check_monitor(Pid) :-
    test_supervisor_restart:identities(Pid,Id,N),
    retract(test_supervisor_restart:monitor_failure(Id,N)), throw(monitor_error(Id)).
actors:hook_check_send(Pid, '$stop'(_, _)) :-
    test_supervisor_restart:observe_stop(Pid).

observe_stop(Pid) :-
    identities(Pid,Id,N), actors:resolve_actor_thread(Pid,_), observer(Events),
    thread_send_message(Events,stopping(Id,N)),
    (retract(stop_fault(Id,Error)) -> throw(Error);true).

callback(hold,Parent,ok,Parent) :- !,
    send(Parent,restart_callback_held),receive({never -> true}).
callback(_,State,ok,State).
starting(Id) :-
    with_mutex(supervisor_restart_test,
      ((retract(attempts(Id,Old))->N is Old+1;N=1),assertz(attempts(Id,N)))),
    self(Pid), assertz(identities(Pid,Id,N)),
    (failure(Id,N) -> throw(replacement_error(Id));true).

reset :-
    retractall(attempts(_,_)),retractall(identities(_,_,_)),
    retractall(failure(_,_)),retractall(observer(_)),retractall(stop_fault(_,_)),
    retractall(monitor_failure(_,_)).
:- meta_predicate fixture(0).
fixture(Goal) :-
    gensym(supervisor_restart_events_,Events),
    setup_call_cleanup((reset,message_queue_create(_,[alias(Events)]),assertz(observer(Events))),
                      Goal,(reset,message_queue_destroy(Events))).

child(Id,Policy,child(Id,[start(server(test_supervisor_restart:callback,
    [src_list([(:- test_supervisor_restart:starting(Id))])])),restart(permanent),shutdown(Policy)])).

stop_actor(Pid) :-
    setup_call_cleanup(monitor(Pid,Ref),
      (exit(Pid,kill),receive({down(Pid,Ref,_) -> true},[timeout(3),on_timeout(fail)])),
      demonitor(Ref,[flush])).
cleanup_supervisor(Sup) :- demonitor(Sup,[flush]),stop_actor(Sup).
assert_dead(Pid) :- assertion(\+ actors:resolve_actor_thread(Pid,_)).
% thread_get_message/3 is deterministic: explicitly recurse to drain the
% fixture's private event queue, leaving the actor mailbox untouched.
read_stops(Stops) :-
    observer(Events),read_stops(Events,Stops).
read_stops(Events,Stops) :-
    (thread_get_message(Events,stopping(Id,N),[timeout(0)])
    -> Stops=[Id-N|Rest],read_stops(Events,Rest)
    ; Stops=[]).

failure_ids(one_for_one,b,b).
failure_ids(one_for_all,a,b).
failure_ids(rest_for_one,b,c).

automatic(Strategy,Mode) :-
    failure_ids(Strategy,Trigger,Failed),
    (Mode==monitor_error -> assertz(monitor_failure(Failed,2));assertz(failure(Failed,2))),
    (Mode==policies -> AP=0.02,CP=brutal_kill;AP=infinity,CP=0.1),
    child(a,AP,A0),child(b,0.1,B),child(c,CP,C),self(Self),
    (Mode==policies
    -> A0=child(a,AOpts),selectchk(start(server(CB,Opts)),AOpts,Rest),
       A=child(a,[start(server(CB,[initial_state(Self)|Opts]))|Rest])
    ; A=A0),
    setup_call_cleanup(
      supervisor_spawn(test_supervisor_restart:[A,B,C],Sup,
          [strategy(Strategy),intensity(5),monitor(true),link(false)]),
      check_automatic(Sup,Strategy,Mode,Trigger,Failed),
      cleanup_supervisor(Sup)).

check_automatic(Sup,Strategy,Mode,Trigger,Failed) :-
    supervisor_which_children(Sup,Children),
    Children=[info(a,PA,_,_),info(b,PB,_,_),info(c,PC,_,_)],
    setup_call_cleanup(
      (monitor(PA,RA),monitor(PB,RB),monitor(PC,RC),monitor(Sup,ExtraSup)),
      (self(Self),send(Self,unrelated_restart_message),
       (Mode==policies
       -> make_ref(Request),send(PA,'$call'(Self,Request,hold)),
          receive({restart_callback_held -> true},[timeout(2),on_timeout(fail)])
       ; true),
       (Mode==cleanup_error -> assertz(stop_fault(c,cleanup_error(c)));true),
       memberchk(info(Trigger,TriggerPid,_,_),Children),server_halt(TriggerPid,_),
       (Mode==monitor_error -> Expected=restart_failed(Failed,monitor_error(Failed))
       ;Expected=restart_failed(Failed,replacement_error(Failed))),
       receive({down(Sup,Sup,Reason) -> true},[timeout(4),on_timeout(fail)]),
       assertion(Reason==Expected),
       receive({down(Sup,ExtraSup,ExtraReason) -> true},[timeout(0),on_timeout(fail)]),
       assertion(ExtraReason==Expected),
       (Mode==policies -> AReason=shutdown,CReason=kill
       ;Mode==cleanup_error -> AReason=true,CReason=shutdown
       ;AReason=true,CReason=true),
       receive({down(PA,RA,ActualA) -> true},[timeout(1),on_timeout(fail)]),assertion(ActualA==AReason),
       receive({down(PB,RB,ActualB) -> true},[timeout(1),on_timeout(fail)]),assertion(ActualB==true),
       receive({down(PC,RC,ActualC) -> true},[timeout(1),on_timeout(fail)]),assertion(ActualC==CReason),
       receive({unrelated_restart_message -> true},[timeout(0),on_timeout(fail)]),
       forall(identities(P,_,_),assert_dead(P)),
       whereis(a,undefined),whereis(b,undefined),whereis(c,undefined),
       test_supervisor_restart:check_replacements(Strategy),
       read_stops(Stops0),exclude(=(Failed-2),Stops0,Stops),
       (Mode==normal -> test_supervisor_restart:check_stopping_order(Strategy,Stops);true)),
      (demonitor(RA,[flush]),demonitor(RB,[flush]),demonitor(RC,[flush]),demonitor(ExtraSup,[flush]))).

check_replacements(one_for_one) :- attempts(a,1),attempts(b,2),attempts(c,1).
check_replacements(one_for_all) :- attempts(a,2),attempts(b,2),attempts(c,1).
check_replacements(rest_for_one) :- attempts(a,1),attempts(b,2),attempts(c,2).
check_stopping_order(one_for_one,Stops) :- assertion(Stops==[b-1,c-1,a-1]).
check_stopping_order(one_for_all,Stops) :- assertion(Stops==[a-1,b-1,c-1,a-2]).
check_stopping_order(rest_for_one,Stops) :- assertion(Stops==[b-1,c-1,b-2,a-1]).

:- begin_tests(supervisor_restart).

test(explicit_failure_preserves_inactive_spec_sibling_and_retry) :-
    fixture(
      (child(explicit,0.1,Spec),child(stable,infinity,Stable),
       setup_call_cleanup(
         supervisor_spawn(test_supervisor_restart:[Spec,Stable],Sup,[monitor(true),link(false)]),
         (supervisor_which_children(Sup,[info(explicit,Old,worker,permanent),info(stable,Sibling,worker,permanent)]),
          setup_call_cleanup(monitor(Old,AppRef),
             (supervisor_terminate_child(Sup,explicit,ok),
              receive({down(Old,AppRef,true) -> true},[timeout(2),on_timeout(fail)])),
             demonitor(AppRef,[flush])),
          assertz(test_supervisor_restart:failure(explicit,2)),
          supervisor_respawn_child(Sup,explicit,Reply),assertion(Reply==error(replacement_error(explicit))),
          supervisor_which_children(Sup,[info(explicit,undefined,worker,permanent),info(stable,Sibling,worker,permanent)]),
          server_request(Sibling,ping,ok),
          supervisor_count_children(Sup,Counts),assertion(Counts==[specs-2,active-1,supervisors-0,workers-1]),
          whereis(explicit,undefined),test_supervisor_restart:identities(Failed,explicit,2),assert_dead(Failed),
          supervisor_respawn_child(Sup,explicit,Retry),assertion(nonvar(Retry)),Retry=ok(New),assertion(New\==Old),
          supervisor_which_children(Sup,[info(explicit,New,worker,permanent),info(stable,Sibling,worker,permanent)]),
          supervisor_respawn_child(Sup,explicit,Running),assertion(Running==error(running)),
          supervisor_respawn_child(Sup,absent,Missing),assertion(Missing==error(not_found))),
         cleanup_supervisor(Sup)))).

test(automatic_failure_rolls_back_and_reports_actual_failed_child,
     [forall(member(Strategy,[one_for_one,one_for_all,rest_for_one]))]) :-
    fixture(test_supervisor_restart:automatic(Strategy,normal)).

test(group_monitor_failure_reclaims_live_provisional_replacements) :-
    fixture(test_supervisor_restart:automatic(one_for_all,monitor_error)).

test(automatic_failure_respects_numeric_and_brutal_shutdown) :-
    fixture(test_supervisor_restart:automatic(one_for_one,policies)).

test(cleanup_error_preserves_restart_error_and_still_stops_other_children) :-
    fixture(test_supervisor_restart:automatic(one_for_one,cleanup_error)).

test(ordinary_failure_preserves_replies_and_automatic_classification) :-
    self(Self),make_ref(Ref),State=sup(one_for_one,5,5,[ch(inactive,undefined,bad)],[]),
    supervisor_actor:handle_call(restart_child(inactive),Self,Ref,State,After),
    assertion(State==After),
    receive({Ref-Reply -> assertion(Reply==error(start_failed))},[timeout(0),on_timeout(fail)]),
    catch(supervisor_actor:restart_child_record(inactive,bad,_),Error,true),
    assertion(Error==restart_failed(inactive,start_failed)).

test(reserved_controls_propagate,
     [forall(member(Control,['$abort_goal','$ptcp_time_limit']))]) :-
    catch(supervisor_actor:restart_child_error(id,Control),Error,true),assertion(Error==Control).

test(cleanup_control_propagates_and_preserves_application_monitor) :-
    fixture(
      setup_call_cleanup(
        server_spawn(test_supervisor_restart:callback,[],Pid,
           [name(control_probe),src_list([(:-test_supervisor_restart:starting(control_probe))])]),
        setup_call_cleanup(monitor(Pid,AppRef),
          (self(Self),send(Self,unrelated_cleanup_control_message),
           assertz(test_supervisor_restart:stop_fault(control_probe,'$abort_goal')),
           Spec=spec(control_probe,server(test_supervisor_restart:callback,[]),temporary,0.1,worker),
           catch(supervisor_startup:cleanup_children([ch(control_probe,Pid,Spec)]),Error,true),
           assertion(Error=='$abort_goal'),
           receive({down(Pid,AppRef,shutdown) -> true},[timeout(2),on_timeout(fail)]),
           receive({unrelated_cleanup_control_message -> true},[timeout(0),on_timeout(fail)]),
           assert_dead(Pid),whereis(control_probe,undefined)),
          demonitor(AppRef,[flush])),
        stop_actor(Pid))).

:- end_tests(supervisor_restart).
