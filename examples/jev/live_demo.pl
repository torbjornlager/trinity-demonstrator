:- module(jev_live_demo, [
    live_probe/0,
    live_probe/1
]).

/** <module> Optional live Jev probes

This file is never loaded by the ordinary test suite.  It requires the
node-owner `TYPESAFE_API_KEY` environment variable and consumes live API
requests.  Results are observations, not accuracy claims.
*/

:- use_module(deployment_observation).

live_probe :-
    live_probe(["yes", "no", "ja", "nej",
                "Yes, deploy it -- actually no, do not deploy it."]).

live_probe(Texts) :-
    must_be(list, Texts),
    forall(member(Text, Texts),
           ( deployment_observation(Text, Observation),
             print_observation(Text, Observation),
             sleep(0.30) )).

print_observation(Text,
        observation(choice(Intent, Probabilities, Confidence),
                    Urgency, IsQuestion, provenance(Raw))) :-
    !,
    format('~nInput: ~s~n', [Text]),
    format('Model: ~w~n', [Raw.model]),
    format('Intent: ~w~n', [Intent]),
    format('Intent probabilities: ~p~n', [Probabilities]),
    format('Intent confidence: ~2f~n', [Confidence]),
    format('Urgency: ~p~n', [Urgency]),
    format('Question: ~p~n', [IsQuestion]).
print_observation(Text, unavailable(Reason)) :-
    format('~nInput: ~s~nUnavailable: ~p~n', [Text, Reason]).

