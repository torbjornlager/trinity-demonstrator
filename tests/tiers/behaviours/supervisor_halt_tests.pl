% SPDX-License-Identifier: MIT
:- module(supervisor_halt_tests,[run/0]).
:- use_module('../../../prolog/web_prolog/actors.pl').
:- use_module('../../../prolog/web_prolog/supervisor_actor.pl').
run :-
    ordered(reply_first),ordered(down_first),delayed_ack,
    absent(normal_down),absent(pending),abnormal,
    original_deadline,public_monitor_cleanup,
    writeln('Supervisor halt ordering, original deadline and private monitor cleanup: ok').

refs(Self,Ref,Mon,Deadline) :-
    self(Self),make_ref(Ref),make_ref(Mon),get_time(Now),Deadline is Now+0.1.
ordered(Order) :-
    refs(Self,Ref,Mon,Deadline),make_ref(Other),
    send(Self,down(unrelated,Other,unrelated_reason)),
    send(Self,unrelated_message(Ref)),
    (Order==reply_first -> send(Self,Ref-ok),send(Self,down(fake,Mon,true))
    ; send(Self,down(fake,Mon,true)),send(Self,Ref-ok)),
    supervisor_actor:sup_halt_wait(fake,Ref,Mon,Deadline,pending),
    receive({down(unrelated,Other,unrelated_reason) -> true},[timeout(0),on_timeout(fail)]),
    receive({unrelated_message(Ref) -> true},[timeout(0),on_timeout(fail)]),
    (Order==reply_first -> receive({down(fake,Mon,true) -> true},[timeout(0),on_timeout(fail)]) ; true).
delayed_ack :-
    refs(Self,Ref,Mon,Deadline),
    setup_call_cleanup(
        spawn((send(Self,down(fake,Mon,true)),sleep(0.03),send(Self,Ref-ok)),Sender,[link(false)]),
        supervisor_actor:sup_halt_wait(fake,Ref,Mon,Deadline,pending),
        exit(Sender,kill)).
absent(Outcome) :-
    refs(Self,Ref,Mon,Deadline),
    (Outcome==normal_down -> send(Self,down(fake,Mon,true)),Expected=supervisor_down(true)
    ; Expected=supervisor_call_timeout(fake,stop)),
    catch(supervisor_actor:sup_halt_wait(fake,Ref,Mon,Deadline,pending),Error,true),
    Error==Expected.
abnormal :-
    refs(Self,Ref,Mon,Deadline),send(Self,down(fake,Mon,crashed)),
    catch(supervisor_actor:sup_halt_wait(fake,Ref,Mon,Deadline,pending),Error,true),
    Error==supervisor_down(crashed).
original_deadline :-
    self(Self),make_ref(Ref),make_ref(Mon),get_time(Start),Deadline is Start+0.3,
    % Simulate an event arriving late in the original wait.
    sleep(0.18),send(Self,down(fake,Mon,true)),
    catch(supervisor_actor:sup_halt_wait(fake,Ref,Mon,Deadline,pending),Error,true),
    Error==supervisor_down(true),get_time(End),Elapsed is End-Start,
    Elapsed>=0.27,Elapsed<0.43.
public_monitor_cleanup :-
    spawn(receive({'$sup'(From,Ref,stop) -> (send(From,Ref-ok),receive({finish -> true}))}),Pid,[link(false)]),
    setup_call_cleanup(monitor(Pid,Own),
        (supervisor_halt(Pid),
         self(Owner),findall(M,actors:monitor(Owner,Pid,M),[Own]),
         send(Pid,finish),
         receive({down(Pid,Own,true) -> true},[timeout(2),on_timeout(fail)]),
         self(Self),\+actors:monitor(Self,Pid,_)),
        (demonitor(Own,[flush]),exit(Pid,kill))),
    spawn(receive({'$sup'(_,_,stop) -> exit(crashed)}),Bad,[link(false)]),
    catch(supervisor_halt(Bad),Error,true),Error==supervisor_down(crashed),
    self(Self2),\+actors:monitor(Self2,Bad,_).
