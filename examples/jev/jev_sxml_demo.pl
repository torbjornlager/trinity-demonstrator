:- module(jev_sxml_demo, [
    demo_spawn/1,
    demo_spawn/2,
    deployment_decision/2
]).

/** <module> Jev + Web Prolog + SXML vertical demonstrator

The gateway actor serializes natural-language messages, calls Jev outside the
statechart macrostep, and sends one complete semantic observation to SXML.
*/

:- use_module(deployment_observation).
:- use_module('../../prolog/web_prolog/actors').
:- use_module('../../prolog/web_prolog/statechart_actor').

:- meta_predicate demo_spawn(-, 2).

%!  demo_spawn(-Pid) is det.
%!  demo_spawn(-Pid, :Sensor) is det.
%
%   The actor accepts `say(From, Ref, Text)` and `stop`.  Sensor is injectable
%   for deterministic tests and has signature `call(Sensor, Text, Result)`.

demo_spawn(Pid) :-
    demo_spawn(Pid, deployment_observation).

demo_spawn(Pid, Sensor) :-
    chart_path(Chart),
    spawn(demo_actor(Sensor, Chart), Pid, [link(false)]).

chart_path(Chart) :-
    module_property(jev_sxml_demo, file(File)),
    file_directory_name(File, Dir),
    file_directory_name(Dir, ExamplesDir),
    directory_file_path(ExamplesDir,
                        'statecharts/20 jev-deployment-assistant.xml', Chart).

demo_actor(Sensor, ChartSource) :-
    statechart_spawn(Chart, [src_uri(ChartSource), trace(false)]),
    demo_loop(Sensor, Chart).

demo_loop(Sensor, Chart) :-
    receive({
        say(From, Ref, Text) ->
            semantic_observation(Sensor, Text, Observation),
            Chart ! observed(From, Ref, Text, Observation),
            demo_loop(Sensor, Chart);
        stop ->
            statechart_halt(Chart, _Reply, 1)
    }).

semantic_observation(Sensor, Text, Observation) :-
    observe_with(Sensor, Text, Observation).
