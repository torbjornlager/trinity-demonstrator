:- module(demo_services).
:- use_module(actors).
:- import exit/2 from actors.
:- import rpc/3, egress_request/4, query_page/8 from isotope_rpc.
:- lib(prolog_extras).
:- import select/3 from lists.

:- export init_linda/0.
:- export model_chat/2, jev_deployment_observation/2.
:- export statechart_spawn/2, statechart_halt/3, run_chart/1.
:- export linda_out/1, linda_in/1, linda_rd/1, linda_inp/1, linda_rdp/1.
:- local store(linda_service).

% The host adapter still checks the fixed SWI service peer against its
% allowlist. Keep inference and observation in the owner-installed service.
model_chat(Messages, Result) :-
    ( catch(once(rpc('https://n3.elfenbenstornet.se',
                     model_chat(Messages, Reply), [once(true)])),
            error(rpc_error(_), _), fail) ->
        Result = Reply
    ; Result = error(unavailable) ).

jev_deployment_observation(Text, Result) :-
    % SWI dictionaries can contain other dictionaries. Serialize only the
    % provenance as text, keeping the typed observation available to ECLiPSe.
    Goal = (jev_deployment_observation(Text, Raw),
            ( Raw = observation(Choice, Score, Noul, provenance(Dict)) ->
                term_string(Dict, Portable),
                Reply = observation(Choice, Score, Noul, provenance(swi_dict(Portable)))
            ; Reply = Raw )),
    ( catch(query_page("https://n3.elfenbenstornet.se", Goal, Reply, "", 0, 1, true, Answer),
            error(rpc_error(_), _), fail),
      Answer = success([Result], _) ->
        true
    ; Result = unavailable(configuration) ).

% Support the bundled flat Jev chart. The host compiles its SXML document,
% and its datamodel and transition actions run in a private ECLiPSe actor.
statechart_spawn(Pid, Options) :-
    ( is_list(Options),
      select(src_uri(Uri), Options, Rest),
      ( Rest == [] -> Trace = true
      ; Rest = [trace(Trace)], (Trace == true ; Trace == false) ),
      Uri == '/examples/statecharts/20%20jev-deployment-assistant.xml' ->
        egress_request("demo_chart", "", [], Source),
        spawn(demo_services:run_chart(Trace), Pid, [src_text(Source)])
    ; throw(error(domain_error(bundled_statechart_options, Options), statechart_spawn/2)) ).

run_chart(Trace) :-
    self(Self),
    actor_module(Self, Module),
    call(n7_chart_initial(Initial))@Module,
    chart_loop(Initial, Trace, Module).

chart_loop(State, Trace, Module) :-
    receive({
        Event ->
            ( call(n7_chart_step(State, Event, Next))@Module ->
                ( Trace == true, State \== Next ->
                    browser_chart_trace(transition(State, [Next], [State], [Next]))
                ; true )
            ; Next = State ),
            chart_loop(Next, Trace, Module)
    }).

statechart_halt(Pid, Reply, Timeout) :-
    setup_call_cleanup(monitor(Pid, Ref),
        ( exit(Pid, shutdown),
          receive({down(Pid, Ref, _) -> Reply = true},
                  [timeout(Timeout), on_timeout(Reply = timeout)]) ),
        demonitor(Ref, [flush])).

% Reuse the SWI tuple-space protocol and matching rules on a node-owned
% actor. Its lifetime is independent of any browser session.
:- include('linda_space.pl').

init_linda :-
    spawn(linda_loop([], []), Space, [link(false)]),
    store_set(linda_service, space, Space).

linda_out(Tuple) :- linda_call(out(Tuple), ok).
linda_in(Tuple) :- linda_call(in(Tuple), tuple(Tuple)).
linda_rd(Tuple) :- linda_call(rd(Tuple), tuple(Tuple)).
linda_inp(Tuple) :- linda_call(inp(Tuple), tuple(Tuple)).
linda_rdp(Tuple) :- linda_call(rdp(Tuple), tuple(Tuple)).

linda_call(Operation, Result) :-
    store_get(linda_service, space, Space),
    self(Me),
    fresh_reference(Ref),
    setup_call_cleanup(monitor(Space, Monitor),
        ( Space ! linda(Me, Ref, Operation),
          receive({
              linda_reply(Ref, Reply) -> linda_result(Reply, Result)
          ; down(Space, Monitor, Reason) -> throw(linda_down(Reason))
          }) ),
        ( Space ! linda_cancel(Me, Ref), demonitor(Monitor, [flush]) )).

linda_result(error(Reason), _) :- !, throw(linda_error(Reason)).
linda_result(missing, _) :- !, fail.
linda_result(Reply, Reply).
