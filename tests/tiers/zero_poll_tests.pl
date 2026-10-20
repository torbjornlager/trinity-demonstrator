:- module(test_zero_poll, []).
:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module(library(plunit)).
:- use_module(library(process)).
:- use_module(library(readutil)).

child_case(Mode) :-
    source_file(test_zero_poll:child_case(_),Source),
    file_directory_name(Source,Dir),
    directory_file_path(Dir,'fixtures/zero_poll_cleanup.pl',Fixture),
    current_prolog_flag(executable,Exe),State=child(running),
    setup_call_cleanup(
      process_create(Exe,['-q','-s',Fixture,'--',Mode],
                     [process(Pid),stdout(pipe(Out)),stderr(pipe(Err))]),
      (get_time(Start),Deadline is Start+2,wait_child(Pid,Deadline,Status),
       (Status==timeout -> process_kill(Pid,kill),process_wait(Pid,_);true),
       nb_setarg(1,State,reaped),
       read_string(Out,_,Output),read_string(Err,_,Errors),
       assertion(result(Status,Output,Errors)==result(exit(0),"completed\n",""))),
      ((arg(1,State,reaped) -> true
       ; catch(process_kill(Pid,kill),_,true),catch(process_wait(Pid,_),_,true)),
       close(Out),close(Err))).

% Use nonblocking process reaping: positive process_wait timeouts are not
% implemented uniformly across hosts, and the child may mask Prolog signals.
wait_child(Pid, Deadline, Status) :-
    process_wait(Pid, NowStatus, [timeout(0)]),
    (   NowStatus == timeout
    ->  get_time(Now),
        (Now >= Deadline -> Status=timeout
        ; sleep(0.01),wait_child(Pid,Deadline,Status))
    ;   Status=NowStatus
    ).

:- begin_tests(zero_poll).

test(pending_signal_in_cleanup,
     [forall(member(Mode,[empty_integer,empty_float,selection,monitor_flush]))]) :-
    child_case(Mode).

test(negative_timeout_does_not_consume) :-
    self(Self),send(Self,negative_timeout_marker),
    receive({negative_timeout_marker -> fail},[timeout(-1),on_timeout(Outcome=expired)]),
    assertion(Outcome==expired),
    receive({negative_timeout_marker -> true},[timeout(0),on_timeout(fail)]).

test(host_option_validation_is_preserved,
     [throws(error(domain_error(signal_option,bad),_))]) :-
    receive({absent -> true},[timeout(0),signals(bad)]).

test(malformed_list_validation_is_preserved,
     [throws(error(type_error(list,_),_))]) :-
    receive({absent -> true},[timeout(0)|bad]).

:- end_tests(zero_poll).
