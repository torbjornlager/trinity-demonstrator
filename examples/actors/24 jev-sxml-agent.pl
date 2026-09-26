%% Stage 2: Jev + Web Prolog + SXML.
%
% This serial gateway uses exactly the same observation returned to Stage 1.
% External inference finishes before observed/4 enters the statechart, so the
% chart performs no provider I/O during its run-to-completion macrostep.

jev_sxml_agent_spawn(Pid) :-
    spawn(jev_sxml_agent, Pid, [
        src_predicates([jev_sxml_agent/0, jev_sxml_agent_loop/1,
                        jev_observation/2]),
        monitor(true)
    ]).

jev_sxml_agent :-
    statechart_spawn(Chart, [
        src_uri('/examples/statecharts/20%20jev-deployment-assistant.xml'),
        trace(true)
    ]),
    jev_sxml_agent_loop(Chart).

jev_sxml_agent_loop(Chart) :-
    receive({
        say(From, Ref, Text) ->
            jev_observation(Text, Observation),
            Chart ! observed(From, Ref, Text, Observation),
            jev_sxml_agent_loop(Chart);
        stop ->
            statechart_halt(Chart, _Reply, 1)
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

/** <examples>

?- jev_sxml_agent_spawn(Pid).

?- self(Me), $Pid ! say(Me, first, "yes"),
   receive({demo_reply(first, Report) -> true},
           [timeout(20), on_timeout(fail)]).

?- self(Me), $Pid ! say(Me, deploy, "Please prepare a deployment"),
   receive({demo_reply(deploy, Report) -> true},
           [timeout(20), on_timeout(fail)]).

?- self(Me), $Pid ! say(Me, swedish, "ja"),
   receive({demo_reply(swedish, Report) -> true},
           [timeout(20), on_timeout(fail)]).

?- $Pid ! stop.

*/
