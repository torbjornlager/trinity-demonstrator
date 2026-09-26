%% Stage 1: Jev + an ordinary Web Prolog actor.
%
% The node-owned capability turns text into a typed, uncertain semantic
% observation. Ordinary Prolog clauses choose a conversational/simulated
% action. There is deliberately no SXML statechart in this example.

jev_agent_spawn(Pid) :-
    spawn(jev_agent, Pid, [
        src_predicates([jev_agent/0, jev_agent_loop/0, jev_observation/2,
                        jev_stage1_decision/3, jev_confident/1,
                        jev_intent/2]),
        monitor(true)
    ]).

jev_agent :-
    jev_agent_loop.

jev_agent_loop :-
    receive({
        say(From, Ref, Text) ->
            jev_observation(Text, Observation),
            jev_stage1_decision(Observation, Action, Reply),
            From ! agent_reply(Ref,
                      report(Text, Observation, action(Action), Reply)),
            jev_agent_loop;
        stop ->
            true
    }).

jev_observation(Text, Observation) :-
    catch(jev_deployment_observation(Text, Candidate),
          error(existence_error(procedure, _), _),
          Candidate = unavailable(configuration)),
    (   Candidate = observation(choice(_, _, _), score(_, _, _, _),
                                noul(_), provenance(Raw)),
        is_dict(Raw)
    ->  Observation = Candidate
    ;   Candidate = unavailable(Reason)
    ->  Observation = unavailable(Reason)
    ;   Observation = unavailable(malformed_observation)
    ).

jev_stage1_decision(unavailable(Reason), retry_later,
                    reply(unavailable(Reason),
                          "The semantic service is unavailable; no action was taken.")) :-
    !.
jev_stage1_decision(Observation, clarify,
                    reply(clarification,
                          "I am not confident enough to act. Please rephrase.")) :-
    \+ jev_confident(Observation),
    !.
jev_stage1_decision(Observation, prepare_preview,
                    reply(prepared,
                          "I prepared a simulated deployment preview; nothing was deployed.")) :-
    jev_intent(Observation, request_deploy),
    !.
jev_stage1_decision(Observation, show_status,
                    reply(status,
                          "There is no real deployment; this demonstrator is idle.")) :-
    jev_intent(Observation, status),
    !.
jev_stage1_decision(Observation, explain_context,
                    reply(no_context,
                          "There is no pending question for that answer.")) :-
    jev_intent(Observation, Intent),
    memberchk(Intent, [affirm, deny]),
    !.
jev_stage1_decision(_, clarify,
                    reply(clarification,
                          "Ask me to prepare a deployment preview or report status.")).

jev_confident(observation(choice(_, _, Confidence), _, _, _)) :-
    Confidence >= 0.70.

jev_intent(observation(choice(Intent, _, _), _, _, _), Intent).

/** <examples>

?- jev_agent_spawn(Pid).

?- self(Me), $Pid ! say(Me, deploy, "Please prepare a deployment"),
   receive({agent_reply(deploy, Report) -> true},
           [timeout(20), on_timeout(fail)]).

?- self(Me), $Pid ! say(Me, status, "What is the deployment status?"),
   receive({agent_reply(status, Report) -> true},
           [timeout(20), on_timeout(fail)]).

?- $Pid ! stop.

*/
