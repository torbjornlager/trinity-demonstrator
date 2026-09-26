:- module(jev_actor, [
    deployment_actor_spawn/1,
    deployment_actor_spawn/2,
    stage1_decision/3
]).

/** <module> Stage 1: a complete Jev + Web Prolog agent

The actor observes through the shared semantic sensor, thinks with ordinary
clauses, and acts by sending a conversational/simulated reply.  It has no
statechart and needs none for this stateless interaction.
*/

:- use_module(deployment_observation).
:- use_module('../../prolog/web_prolog/actors').

:- meta_predicate deployment_actor_spawn(-, 2).

%!  deployment_actor_spawn(-Pid) is det.
%!  deployment_actor_spawn(-Pid, :Sensor) is det.
%
%   Spawn an actor accepting `say(From, Ref, Text)` and `stop`.  Sensor is
%   injectable for deterministic tests and returns a decision or observation.

deployment_actor_spawn(Pid) :-
    deployment_actor_spawn(Pid, deployment_observation).

deployment_actor_spawn(Pid, Sensor) :-
    spawn(deployment_actor_loop(Sensor), Pid, [link(false)]).

deployment_actor_loop(Sensor) :-
    receive({
        say(From, Ref, Text) ->
            observe_with(Sensor, Text, Observation),
            stage1_decision(Observation, Action, Reply),
            From ! agent_reply(Ref,
                      report(Text, Observation, action(Action), Reply)),
            deployment_actor_loop(Sensor);
        stop ->
            true
    }).

stage1_decision(unavailable(Reason), retry_later,
                reply(unavailable(Reason),
                      "The semantic service is unavailable; no action was taken.")) :-
    !.
stage1_decision(Observation, clarify,
                reply(clarification,
                      "I am not confident enough to act. Please rephrase.")) :-
    \+ confident_observation(Observation, 0.70),
    !.
stage1_decision(Observation, prepare_preview,
                reply(prepared,
                      "I prepared a simulated deployment preview; nothing was deployed.")) :-
    observation_intent(Observation, request_deploy),
    !.
stage1_decision(Observation, show_status,
                reply(status,
                      "There is no real deployment; this demonstrator is idle.")) :-
    observation_intent(Observation, status),
    !.
stage1_decision(Observation, explain_context,
                reply(no_context,
                      "There is no pending question for that answer.")) :-
    observation_intent(Observation, Intent),
    memberchk(Intent, [affirm, deny]),
    !.
stage1_decision(_, clarify,
                reply(clarification,
                      "Ask me to prepare a deployment preview or report status.")).
