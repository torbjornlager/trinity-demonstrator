:- module(jev_service, [
    configure_jev_service/0,
    jev_deployment_observation/2,
    portable_jev_observation/2
]).

/** <module> Owner-installed, bounded Jev capability for the tutorial

Public actors can ask one fixed set of deployment-dialogue questions.  They
cannot select an endpoint, model, question, or credential.  Enable explicitly
at node startup; the underlying transport reads `TYPESAFE_API_KEY` and optional
`TYPESAFE_ENDPOINT` from the owner environment.
*/

:- use_module('../jev/deployment_observation').
:- use_module('../example_text').
:- use_module('../portable_json_swi', [portable_json_from_dict/2]).
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
    (   bounded_native_text(Text,500,Native,Length),Length>0
    ->  setup_call_cleanup(
            admit(Request),
            perform(Request, Native, Result),
            release(Request))
    ;   Result = unavailable(invalid_text)
    ).

valid_text(Text) :-
    bounded_native_text(Text,500,_,Length),Length>0.

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
    deployment_observation(Text, Native),
    portable_jev_observation(Native, Result).

% Native dicts belong to the provider adapter. Public actors on every engine
% receive the same inspectable JSON terms, including all provenance fields.
portable_jev_observation(unavailable(Reason), unavailable(Reason)) :- !.
portable_jev_observation(
        observation(choice(Intent, Probabilities, Confidence),
                    score(Value, Legend, Distribution, Certainty),
                    Noul, provenance(Raw)),
        observation(choice(Intent, PortableProbabilities, Confidence),
                    score(Value, PortableLegend, PortableDistribution, Certainty),
                    Noul, provenance(PortableRaw))) :-
    portable_json_from_dict(Probabilities, PortableProbabilities),
    dict_pairs(Legend, Tag, LegendPairs),
    maplist(native_legend_pair, LegendPairs, NativePairs),
    dict_pairs(NativeLegend, Tag, NativePairs),
    portable_json_from_dict(NativeLegend, PortableLegend),
    portable_json_from_dict(Distribution, PortableDistribution),
    portable_json_from_dict(Raw, PortableRaw).

release(rejected(_)) :- !.
release(started) :-
    with_mutex(jev_admission,
        ( retract(service_state(true, Next)),
          assertz(service_state(false, Next)) )).

% Jev's typed legend has already adopted the language's text convention.
% Restore native JSON strings at this known text field, never by guessing
% whether an arbitrary JSON array of characters represents text.
native_legend_pair(Key-Text, Key-Native) :-
    ( native_text(Text, String) -> Native=String ; Native=Text ).
