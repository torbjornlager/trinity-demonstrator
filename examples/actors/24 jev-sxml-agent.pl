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
    (   ground(Candidate),
        Candidate = observation(choice(Intent, _, Confidence),
                                score(Value, _, _, Certainty),
                                noul(Question), provenance(Raw)),
        memberchk(Intent, [request_deploy, affirm, deny, status, other]),
        number(Confidence), Confidence >= 0, Confidence =< 1,
        number(Value), number(Certainty), Certainty >= 0, Certainty =< 1,
        number(Question), Question >= 0, Question =< 1,
        nonvar(Raw), Raw = json(Pairs), is_list(Pairs)
    ->  Observation = Candidate
    ;   nonvar(Candidate), Candidate = unavailable(Reason)
    ->  Observation = unavailable(Reason)
    ;   Observation = unavailable(malformed_observation)
    ).

/** <examples>

?- jev_sxml_agent_spawn(Pid).

?- self(Me), $Pid ! say(Me, first, "yes"),
   receive({demo_reply(first, Report) -> true ;
            down($Pid, $Pid, Reason) -> throw(agent_down(Reason))},
           [timeout(20), on_timeout(fail)]).

?- self(Me), $Pid ! say(Me, deploy, "Please prepare a deployment"),
   receive({demo_reply(deploy, Report) -> true ;
            down($Pid, $Pid, Reason) -> throw(agent_down(Reason))},
           [timeout(20), on_timeout(fail)]).

?- self(Me), $Pid ! say(Me, swedish, "ja"),
   receive({demo_reply(swedish, Report) -> true ;
            down($Pid, $Pid, Reason) -> throw(agent_down(Reason))},
           [timeout(20), on_timeout(fail)]).

?- $Pid ! stop.

*/
