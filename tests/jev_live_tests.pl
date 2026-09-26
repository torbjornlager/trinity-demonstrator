:- use_module('../examples/jev/deployment_observation').
:- use_module(library(plunit)).

/** <file> Optional live contract smoke test

Run explicitly with `TYPESAFE_API_KEY` set.  This test checks only the current
adapter contract and value bounds; it does not assert a stochastic label or
belong in the offline suite.
*/

:- begin_tests(jev_live).

test(current_adapter_returns_a_complete_observation,
    [condition((getenv('TYPESAFE_API_KEY', Key), Key \== ''))]) :-
    deployment_observation("Please prepare a deployment", Observation),
    Observation = observation(choice(_, Probabilities, Confidence),
                              score(_, Legend, ScoreProbabilities,
                                    ScoreConfidence),
                              noul(QuestionProbability),
                              provenance(Raw)),
    assertion(is_dict(Probabilities)),
    assertion(is_dict(Legend)),
    assertion(is_dict(ScoreProbabilities)),
    assertion(between_zero_and_one(Confidence)),
    assertion(between_zero_and_one(ScoreConfidence)),
    assertion(between_zero_and_one(QuestionProbability)),
    assertion(is_dict(Raw)),
    assertion(get_dict(model, Raw, _)),
    assertion(get_dict(usage, Raw, _)).

:- end_tests(jev_live).

between_zero_and_one(Value) :-
    number(Value),
    Value >= 0.0,
    Value =< 1.0.
