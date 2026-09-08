/* Exercise the exact self-contained SXML source served by the demonstrator. */
:- module(service_request_example_tests, []).
:- use_module('../../../prolog/web_prolog/actors.pl').
:- use_module('../../../prolog/web_prolog/statechart_actor.pl').
:- use_module(library(plunit)).
:- use_module(library(readutil)).
:- dynamic example_file/1.
:- prolog_load_context(directory, Here),
   directory_file_path(Here, '../../../examples/statecharts/18 service-request.xml', File),
   assertz(example_file(File)).
:- meta_predicate scenario(+, 1).

scenario(Case, Body) :-
    example_file(File), read_file_to_string(File, Original, []),
    % Keep tests quick while using real SXML timers and the shipped chart.
    ( Case == silent -> atomic_list_concat(Parts, 'after="8"', Original),
                        atomic_list_concat(Parts, 'after="0.05"', XML)
    ; Case == dispatch_timeout -> atomic_list_concat(Parts, 'after="5"', Original),
                                 atomic_list_concat(Parts, 'after="0.05"', XML)
    ; XML = Original ),
    self(Self), make_ref(Key),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(XML), src_list([demo_observer(Self)]),
                              monitor(true), trace(false)]),
        (send(Pid, start(Key, Case)), call_with_time_limit(4, once(call(Body, handle(Pid,Key))))),
        cleanup(Pid)).
cleanup(Pid) :-
    exit(Pid, kill),
    receive({ down(Pid,Pid,_) -> true }, [timeout(2),on_timeout(throw(missing_down(Pid)))]),
    self(Self), make_ref(Ref), send(Self, drain_end(Ref)), drain(Ref).
drain(Ref) :-
    receive({ drain_end(Ref) -> true;
              notice(_,dispatch_requested(_,_,_,_,_)) -> throw(unexpected_dispatch);
              _ -> drain(Ref) }).
await(Pattern) :- receive({ Pattern -> true }, [timeout(3),on_timeout(throw(missing(Pattern)))]).
confirm(handle(P,K),R,Fs) :- await(notice(P,summary(R,Fs))), send(P,authenticated(K,alice,confirm(R,Fs))).
finish(P,R,Fs,Result) :- await(notice(P,dispatch_requested(_,R,_,alice,Fs))), await(notice(P,terminal(R,Result))).

:- begin_tests(service_request_example).
test(laptop_success) :- scenario(laptop, success_case).
test(forbidden) :- scenario(restricted, forbidden_case).
test(conflict_requires_reviewer) :- scenario(vpn, review_case).
test(missing_fields_require_correction) :- scenario(missing, missing_case).
test(policy_gap_can_be_rejected) :- scenario(training, gap_case).
test(stale_reply_and_confirmation) :- scenario(slow, stale_case).
test(unauthorized_and_changed_snapshot) :- scenario(laptop, unauthorized_case).
test(invalid_model_reply) :- scenario(invalid, invalid_case).
test(model_error) :- scenario(model_error, model_error_case).
test(model_timer) :- scenario(silent, model_timer_case).
test(dispatch_refusal) :- scenario(dispatch_failure, dispatch_failure_case).
test(dispatch_timer_unknown) :- scenario(dispatch_timeout, dispatch_timeout_case).
:- end_tests(service_request_example).

success_case(H) :- H=handle(P,_),confirm(H,1,Fs),finish(P,1,Fs,succeeded(ticket_42)).
forbidden_case(H) :- H=handle(P,_),confirm(H,1,_),await(notice(P,terminal(1,rejected(policy)))).
review_case(H) :-
 H=handle(P,K),confirm(H,1,Fs),await(notice(P,human_review(1,Fs,conflicting))),
 send(P,authenticated(K,alice,review(1,Fs,approve))),await(notice(P,ignored_event)),
 send(P,authenticated(K,reviewer,review(1,Fs,approve))),finish(P,1,Fs,succeeded(ticket_42)).
missing_case(H) :-
 H=handle(P,K),confirm(H,1,Fs),await(notice(P,human_review(1,Fs,insufficient(missing_fields)))),
 send(P,authenticated(K,reviewer,review(1,Fs,approve))),await(notice(P,ignored_event)),
 send(P,authenticated(K,alice,correction(1,laptop))),confirm(H,2,New),finish(P,2,New,succeeded(ticket_42)).
gap_case(H) :-
 H=handle(P,K),confirm(H,1,Fs),await(notice(P,human_review(1,Fs,insufficient(policy_gap)))),
 send(P,authenticated(K,reviewer,review(1,Fs,reject))),await(notice(P,terminal(1,rejected(reviewer)))).
stale_case(H) :-
 H=handle(P,K),await(notice(P,model_requested(_,1,slow))),
 send(P,authenticated(K,alice,correction(1,laptop))),await(notice(P,summary(2,Fs))),
 await(notice(P,ignored_event)), % the two-second old model reply
 send(P,authenticated(K,alice,confirm(1,[cost(1),service(restricted)]))),await(notice(P,ignored_event)),
 send(P,authenticated(K,alice,confirm(2,Fs))),finish(P,2,Fs,succeeded(ticket_42)).
unauthorized_case(H) :-
 H=handle(P,K),await(notice(P,summary(1,Fs))),
 send(P,authenticated(wrong_key,alice,confirm(1,Fs))),await(notice(P,ignored_event)),
 send(P,authenticated(K,mallory,confirm(1,Fs))),await(notice(P,ignored_event)),
 send(P,authenticated(K,alice,confirm(1,[cost(1),service(laptop)]))),await(notice(P,ignored_event)),
 send(P,authenticated(K,alice,confirm(1,Fs))),finish(P,1,Fs,succeeded(ticket_42)).
invalid_case(handle(P,_)) :- await(notice(P,terminal(1,failed(invalid_model_reply)))).
model_error_case(handle(P,_)) :- await(notice(P,terminal(1,failed(model(unavailable))))).
model_timer_case(handle(P,_)) :- await(notice(P,terminal(1,failed(model_timeout)))).
dispatch_failure_case(H) :- H=handle(P,_),confirm(H,1,Fs),finish(P,1,Fs,failed(dispatch(refused))).
dispatch_timeout_case(H) :- H=handle(P,_),confirm(H,1,Fs),finish(P,1,Fs,failed(dispatch_timeout_unknown)).
