:- module(demo_services).
:- use_module(actors).
:- import exit/2 from actors.
:- import egress_request/4, egress_request/5, query_page/8 from isotope_rpc.
:- lib(prolog_extras).
:- use_module(sxml_document).
:- use_module(statechart_actor).
:- reexport statechart_validate/2, statechart_validate_text/2 from sxml_document.
:- reexport statechart_spawn/2, statechart_halt/2, statechart_halt/3 from statechart_actor.

:- export init_linda/0.
:- export model_chat/2, jev_deployment_observation/2.
:- export published_counter/1.
:- export linda_out/1, linda_in/1, linda_rd/1, linda_inp/1, linda_rdp/1.
:- local store(linda_service).

published_counter(Count) :-
    egress_request("published_counter", "https://n3.elfenbenstornet.se", [], Text),
    number_string(Count, Text).

% The host adapter still checks the fixed SWI service peer against its
% allowlist. Keep inference and observation in the owner-installed service.
model_chat(Messages, Result) :-
    ( is_list(Messages), model_messages(Messages, user, Texts), Texts \== [] ->
        ( catch(fetch_model_reply(Texts, Reply), error(rpc_error(_), _), fail) ->
            model_reply(Reply, Result)
        ; Result = error(unavailable) )
    ; Result = error(invalid_messages) ).

model_messages([], assistant, []).
model_messages([Message|Messages], Role, [Text|Texts]) :-
    nonvar(Message),
    Message =.. [Role, Value],
    text_string(Value, Text),
    ( Role == user -> Next = assistant ; Next = user ),
    model_messages(Messages, Next, Texts).

fetch_model_reply(Texts, Reply) :-
    egress_request("model_chat", "https://n3.elfenbenstornet.se", [messages:Texts], 40, Body),
    setup_call_cleanup(open(string(Body), read, Stream),
        ( read(Stream, Reply), read(Stream, end_of_file), at_eof(Stream) ),
        close(Stream)),
    nonvar(Reply),
    ( Reply = answer(_) ; Reply = error(_) ).

model_reply(answer(Text), answer(String)) :- text_string(Text, String), !.
model_reply(Reply, Reply).

jev_deployment_observation(Text, Result) :-
    % Keep the typed observation and its scalar fields. SWI dicts have
    % different syntax on the wire, so carry those fields as opaque text.
    Goal = (jev_deployment_observation(Text, Raw),
            ( Raw = observation(choice(Intent, Probabilities, Confidence),
                                score(Value, Legend, Distribution, Certainty),
                                Noul, provenance(Provenance)) ->
                term_string(Probabilities, ProbabilitiesText),
                term_string(Legend, LegendText),
                term_string(Distribution, DistributionText),
                term_string(Provenance, ProvenanceText),
                Reply = observation(choice(Intent, swi_dict(ProbabilitiesText), Confidence),
                                    score(Value, swi_dict(LegendText),
                                          swi_dict(DistributionText), Certainty),
                                    Noul, provenance(swi_dict(ProvenanceText)))
            ; Reply = Raw )),
    ( catch(query_page("https://n3.elfenbenstornet.se", Goal, Reply, "", 0, 1, true, Answer),
            error(rpc_error(_), _), fail),
      Answer = success([Result], _) ->
        true
    ; Result = unavailable(configuration) ).

% Reuse the SWI tuple-space protocol and matching rules on a node-owned
% actor. Its lifetime is independent of any browser session.
:- include('linda_space.pl').

init_linda :-
    spawn(linda_loop([], []), Space, [link(false)]),
    spawn(linda_contact(Space), Contact, [link(false)]),
    register(linda, Contact),
    store_set(linda_service, space, Space).

linda_contact(Space) :-
    receive({ linda_connect(Client, Ref) -> Client ! linda_connected(Ref, Space) }),
    linda_contact(Space).

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
