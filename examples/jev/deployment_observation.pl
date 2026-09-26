:- module(deployment_observation, [
    deployment_observation/2,
    deployment_decision/2,
    observe_with/3,
    normalize_observation/2,
    observation_intent/2,
    confident_observation/2
]).

/** <module> Application-facing semantic observations for the Jev examples

This small layer is the boundary shared by the plain actor and the SXML
actor.  It owns the deployment vocabulary and converts the general Jev
typed probabilistic decision into a Trinity semantic observation.  Provider
exceptions never become semantic intents: they become explicit
`unavailable/1` values.
*/

:- use_module(jev).
:- use_module(library(error)).

:- meta_predicate observe_with(2, +, -).

%!  deployment_observation(+Text, -Observation) is det.
%
%   Obtain and validate one complete deployment observation.  A successful
%   result has the shape
%
%     observation(IntentChoice, UrgencyScore, QuestionNoul, provenance(Raw))
%
%   Raw is the lossless provider response retained for diagnostics and audit.

deployment_observation(Text, Observation) :-
    observe_with(deployment_decision, Text, Observation).

%!  observe_with(:Sensor, +Text, -Observation) is det.
%
%   Call an injectable semantic sensor and normalise its result.  Tests use
%   this seam without network access; both demonstrators use the same code.

observe_with(Sensor, Text, Observation) :-
    catch(call(Sensor, Text, Candidate), Error,
          exception_observation(Error, Candidate)),
    normalize_observation(Candidate, Observation).

%!  deployment_decision(+Text, -Decision) is det.
%
%   Ask the fixed application questions using the provider-independent
%   `jev_decide/3` abstraction.  This predicate deliberately does no acting.

deployment_decision(Text,
        decision(Intent, Urgency, IsQuestion, RawResponse)) :-
    must_be(string, Text),
    jev_decide(_{message:Text}, [
        choice(intent,
               "Which single intent best describes the message?",
               [ request_deploy-"Ask to prepare or perform a deployment",
                 affirm-"Confirm, approve, agree, or say yes",
                 deny-"Reject, cancel, disagree, or say no",
                 status-"Ask for current deployment status",
                 other-"None of the other options is a good fit"
               ], Intent),
        score(urgency,
              "How urgent is the requested response?",
              ["Routine", "Time-sensitive", "Emergency"],
              Urgency),
        noul(is_question,
             "Is the message phrased primarily as a question?",
             IsQuestion)
    ], RawResponse).

normalize_observation(
        decision(Intent, Urgency, IsQuestion, Raw),
        observation(Intent, Urgency, IsQuestion, provenance(Raw))) :-
    valid_intent(Intent),
    valid_score(Urgency),
    valid_noul(IsQuestion),
    is_dict(Raw),
    !.
normalize_observation(
        observation(Intent, Urgency, IsQuestion, provenance(Raw)),
        observation(Intent, Urgency, IsQuestion, provenance(Raw))) :-
    valid_intent(Intent),
    valid_score(Urgency),
    valid_noul(IsQuestion),
    is_dict(Raw),
    !.
normalize_observation(unavailable(Reason), unavailable(Reason)) :-
    nonvar(Reason),
    !.
normalize_observation(_, unavailable(malformed_observation)).

valid_intent(choice(Intent, Probabilities, Confidence)) :-
    memberchk(Intent, [request_deploy, affirm, deny, status, other]),
    probability_distribution(Probabilities),
    get_dict(Intent, Probabilities, WinnerProbability),
    probability(WinnerProbability),
    number(Confidence),
    probability(Confidence).

valid_score(score(Value, Legend, Probabilities, Confidence)) :-
    number(Value),
    is_dict(Legend),
    dict_pairs(Legend, _, LegendPairs),
    LegendPairs \== [],
    probability_distribution(Probabilities),
    dict_pairs(Probabilities, _, ProbabilityPairs),
    pairs_keys(LegendPairs, Keys),
    pairs_keys(ProbabilityPairs, Keys),
    number(Confidence),
    probability(Confidence).

valid_noul(noul(Probability)) :-
    number(Probability),
    probability(Probability).

probability(Value) :-
    Value >= 0.0,
    Value =< 1.0.

probability_distribution(Probabilities) :-
    is_dict(Probabilities),
    dict_pairs(Probabilities, _, Pairs),
    Pairs \== [],
    maplist(probability_pair, Pairs),
    pairs_values(Pairs, Values),
    sum_list(Values, Total),
    Total >= 0.99,
    Total =< 1.01.

probability_pair(_-Value) :-
    number(Value),
    probability(Value).

observation_intent(observation(choice(Intent, _, _), _, _, _), Intent).

confident_observation(
        observation(choice(_, _, Confidence), _, _, _), Threshold) :-
    number(Threshold),
    Confidence >= Threshold.

exception_observation(Error, unavailable(Reason)) :-
    exception_reason(Error, Reason).

exception_reason(error(existence_error(configuration, _), _), configuration) :- !.
exception_reason(error(jev_http_error(401, _), _), authentication) :- !.
exception_reason(error(jev_http_error(429, _), _), rate_limited) :- !.
exception_reason(error(jev_http_error(529, _), _), overloaded) :- !.
exception_reason(error(jev_http_error(Status, _), _), provider(Status)) :- !.
exception_reason(error(jev_invalid_json(_), _), malformed_response) :- !.
exception_reason(error(jev_invalid_response(_), _), malformed_response) :- !.
exception_reason(error(resource_error(jev_response_too_large), _), malformed_response) :- !.
exception_reason(error(domain_error(jev_response, _), _), malformed_response) :- !.
exception_reason(error(existence_error(jev_answer, _), _), malformed_response) :- !.
exception_reason(error(existence_error(jev_answer_field, _), _), malformed_response) :- !.
exception_reason(error(type_error(jev_answer(_), _), _), malformed_response) :- !.
exception_reason(error(jev_unavailable(Underlying), _), Reason) :-
    !,
    (   sub_term(Subterm, Underlying),
        compound(Subterm),
        functor(Subterm, timeout_error, _)
    ->  Reason = timeout
    ;   Reason = transport
    ).
exception_reason(_, transport).
