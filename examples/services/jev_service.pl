:- module(jev_service, [
    configure_jev_service/0,
    jev_deployment_observation/2
]).

/** <module> Owner-installed, bounded Jev capability for the tutorial

Public actors can ask one fixed set of deployment-dialogue questions.  They
cannot select an endpoint, model, question, or credential.  Enable explicitly
at node startup; the underlying transport reads `TYPESAFE_API_KEY` and optional
`TYPESAFE_ENDPOINT` from the owner environment.
*/

:- use_module('../jev/deployment_observation').
:- use_module(library(error)).
:- use_module(library(web_prolog/node_execution_context),
              [current_public_execution_profile/1]).

:- dynamic service_state/2.              % Busy, next admission time

configure_jev_service :-
    (   current_public_execution_profile(_)
    ->  permission_error(configure, jev_service, public_actor)
    ;   true
    ),
    (   getenv('TYPESAFE_API_KEY', Key), Key \== ''
    ->  true
    ;   existence_error(configuration, 'TYPESAFE_API_KEY')
    ),
    with_mutex(jev_admission,
        ( retractall(service_state(_, _)),
          assertz(service_state(false, 0)) )).

%!  jev_deployment_observation(+Text, -Result) is det.
%
%   Result is a complete `observation/4` term or `unavailable/1`. Calls are
%   serialized and admitted at most four times per second for the whole node.
%   This is a tutorial spending guard, not a general multi-tenant quota system.

jev_deployment_observation(Text, Result) :-
    (   valid_text(Text)
    ->  setup_call_cleanup(
            admit(Request),
            perform(Request, Text, Result),
            release(Request))
    ;   Result = unavailable(invalid_text)
    ).

valid_text(Text) :-
    string(Text),
    string_length(Text, Length),
    Length > 0,
    Length =< 500.

admit(Request) :-
    with_mutex(jev_admission, admit_locked(Request)).

admit_locked(rejected(unavailable)) :-
    \+ service_state(_, _),
    !.
admit_locked(rejected(busy)) :-
    service_state(true, _),
    !.
admit_locked(rejected(rate_limited)) :-
    get_time(Now),
    service_state(false, Next),
    Now < Next,
    !.
admit_locked(started) :-
    get_time(Now),
    Next is Now + 0.25,
    retractall(service_state(_, _)),
    assertz(service_state(true, Next)).

perform(rejected(unavailable), _Text, unavailable(configuration)) :- !.
perform(rejected(Reason), _Text, unavailable(Reason)) :- !.
perform(started, Text, Result) :-
    deployment_observation(Text, Result).

release(rejected(_)) :- !.
release(started) :-
    with_mutex(jev_admission,
        ( retract(service_state(true, Next)),
          assertz(service_state(false, Next)) )).
