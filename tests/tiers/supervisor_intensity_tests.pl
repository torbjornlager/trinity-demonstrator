:- module(test_supervisor_intensity, []).
:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/supervisor_actor.pl').
:- use_module('../../prolog/web_prolog/server_actor.pl').
:- use_module('supervisor_restart_tests.pl', []).
:- use_module(library(plunit)).

exhaustion(Strategy, Max, Mode) :-
    (Mode==policies -> AP=0.02,CP=brutal_kill;AP=infinity,CP=0.1),
    test_supervisor_restart:child(a,AP,A0),
    test_supervisor_restart:child(b,0.1,B),
    test_supervisor_restart:child(c,CP,C),self(Self),
    (Mode==policies
    -> A0=child(a,Opts),selectchk(start(server(CB,SO)),Opts,Rest),
       A=child(a,[start(server(CB,[initial_state(Self)|SO]))|Rest])
    ; A=A0),
    setup_call_cleanup(
      supervisor_spawn(test_supervisor_restart:[A,B,C],Sup,
        [strategy(Strategy),intensity(Max),period(100),monitor(true),link(false)]),
      check_exhaustion(Sup,Max,Mode),
      test_supervisor_restart:cleanup_supervisor(Sup)).

check_exhaustion(Sup,Max,Mode) :-
    supervisor_which_children(Sup,[info(a,PA,_,_),info(b,PB,_,_),info(c,PC,_,_)]),
    setup_call_cleanup(
      (monitor(PA,RA),monitor(PC,RC),monitor(Sup,Extra)),
      (allowed_restarts(Max,Sup,PB,Last),
       (Mode==policies
       -> self(Self),make_ref(Request),send(PA,'$call'(Self,Request,hold)),
          receive({restart_callback_held -> true},[timeout(2),on_timeout(fail)])
       ; true),
       (Mode==cleanup_error
       -> assertz(test_supervisor_restart:stop_fault(c,cleanup_error(c)))
       ; true),
       setup_call_cleanup(monitor(Last,RB),
         (self(Caller),send(Caller,unrelated_intensity_message),server_halt(Last,_),
          receive({down(Sup,Sup,Reason) -> true},[timeout(4),on_timeout(fail)]),
          assertion(Reason==shutdown),
          receive({down(Sup,Extra,ExtraReason) -> true},[timeout(0),on_timeout(fail)]),
          assertion(ExtraReason==shutdown),
          receive({down(Last,RB,BReason) -> true},[timeout(1),on_timeout(fail)]),
          assertion(BReason==true),
          (Mode==policies -> AR=shutdown,CR=kill
          ;Mode==cleanup_error -> AR=true,CR=shutdown
          ;AR=true,CR=true),
          receive({down(PA,RA,ActualA) -> true},[timeout(1),on_timeout(fail)]),
          assertion(ActualA==AR),
          receive({down(PC,RC,ActualC) -> true},[timeout(1),on_timeout(fail)]),
          assertion(ActualC==CR),
          receive({unrelated_intensity_message -> true},[timeout(0),on_timeout(fail)])),
         demonitor(RB,[flush])),
       Starts is Max+1,
       assertion(test_supervisor_restart:attempts(b,Starts)),
       assertion(test_supervisor_restart:attempts(a,1)),
       assertion(test_supervisor_restart:attempts(c,1)),
       forall(test_supervisor_restart:identities(P,_,_),test_supervisor_restart:assert_dead(P)),
       whereis(a,undefined),whereis(b,undefined),whereis(c,undefined),
       test_supervisor_restart:read_stops(Stops),
       (Mode==normal -> expected_stops(Max,Expected),assertion(Stops==Expected);true)),
      (demonitor(RA,[flush]),demonitor(RC,[flush]),demonitor(Extra,[flush]))).

allowed_restarts(0,_,Pid,Pid) :- !.
allowed_restarts(N,Sup,Pid,Last) :-
    setup_call_cleanup(monitor(Pid,Ref),
      (server_halt(Pid,_),
       receive({down(Pid,Ref,true) -> true},[timeout(2),on_timeout(fail)])),
      demonitor(Ref,[flush])),
    % The child down was queued before this request; the reply is a barrier
    % for replacement admission, avoiding timing-based sleeps.
    supervisor_which_children(Sup,[info(a,_,_,_),info(b,New,_,_),info(c,_,_,_)]),
    assertion(ground(New)),assertion(New\==Pid),
    N1 is N-1,allowed_restarts(N1,Sup,New,Last).
expected_stops(0,[b-1,c-1,a-1]).
expected_stops(2,[b-1,b-2,b-3,c-1,a-1]).

:- begin_tests(supervisor_intensity).

test(accounting_preserves_limits_window_and_strict_boundary) :-
    assertion(\+ supervisor_actor:check_intensity(0,5,[],_)),
    supervisor_actor:check_intensity(2,5,[],One),assertion(One=[_]),
    supervisor_actor:check_intensity(2,5,One,Two),assertion(Two=[_,_]),
    assertion(\+ supervisor_actor:check_intensity(2,5,Two,_)),
    get_time(Now),Old is Now-100,Recent is Now+100,
    supervisor_actor:check_intensity(1,5,[Old],Pruned),assertion(Pruned=[_]),
    assertion(\+ supervisor_actor:check_intensity(1,5,[Recent,Old],_)),
    assertion(\+ supervisor_actor:is_recent(10,10)),assertion(supervisor_actor:is_recent(10,11)).

test(zero_budget_stops_children_without_replacement,
     [forall(member(Strategy,[one_for_one,one_for_all,rest_for_one]))]) :-
    test_supervisor_restart:fixture(test_supervisor_intensity:exhaustion(Strategy,0,normal)).

test(exactly_two_restarts_then_exhaustion) :-
    test_supervisor_restart:fixture(test_supervisor_intensity:exhaustion(one_for_one,2,normal)).

test(shutdown_policies_are_honoured) :-
    test_supervisor_restart:fixture(test_supervisor_intensity:exhaustion(one_for_one,0,policies)).

test(cleanup_error_preserves_shutdown_and_attempts_remaining_children) :-
    test_supervisor_restart:fixture(test_supervisor_intensity:exhaustion(one_for_one,0,cleanup_error)).

% Intercept a reserved control during cleanup, before exit(shutdown) commits,
% to inspect the actual cleanup mailbox without catching native abort/0.
% Application down messages and unrelated down-shaped messages must survive.
test(cleanup_control_propagates_and_preserves_same_mailbox_monitors) :-
    test_supervisor_restart:fixture(
      setup_call_cleanup(
        server_spawn(test_supervisor_restart:callback,[],Child,
          [name(intensity_probe),src_list([(:-test_supervisor_restart:starting(intensity_probe))])]),
        setup_call_cleanup(monitor(Child,AppRef),
          (self(Self),send(Self,down(unrelated,application,unrelated_reason)),
           assertz(test_supervisor_restart:stop_fault(intensity_probe,'$abort_goal')),
           Spec=spec(intensity_probe,server(test_supervisor_restart:callback,[]),temporary,0.1,worker),
           catch(supervisor_actor:intensity_exhausted([ch(intensity_probe,Child,Spec)]),Error,true),
           assertion(Error=='$abort_goal'),assertion(\+ actor_terminating),
           receive({down(Child,AppRef,shutdown) -> true},[timeout(2),on_timeout(fail)]),
           receive({down(unrelated,application,unrelated_reason) -> true},[timeout(0),on_timeout(fail)]),
           test_supervisor_restart:assert_dead(Child)),
          demonitor(AppRef,[flush])),
        test_supervisor_restart:stop_actor(Child))).

:- end_tests(supervisor_intensity).
