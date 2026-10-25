:- module(model_service, [configure_model_service/1, model_answer/2, model_chat/2]).

/** <module> Owner-installed, bounded inference capability for example 21.

Only model_answer/2 and model_chat/2 are exposed in the public shared database. It returns to
the calling actor; no return address, URL, model or options come from users.
Enable on ONE node only: limits are process-wide, not cluster-wide.
*/

:- use_module('../example_text').
:- use_module(library(http/http_open)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json)).
:- use_module(library(time)).
:- use_module(library(error)).
:- use_module(library(web_prolog/node_execution_context),
              [current_public_execution_profile/1]).

:- dynamic service_state/4. % endpoint, busy, next admission time, fault

% Owner startup only. Never publish this predicate in the shared database.
configure_model_service(Endpoint) :-
    ( current_public_execution_profile(_)
    -> permission_error(configure, model_service, Endpoint)
    ; true ),
    must_be(atom, Endpoint),
    with_mutex(model_admission,
        ( ( service_state(_, true, _, _) ->
              permission_error(configure, busy_model_service, Endpoint)
          ; true ),
          retractall(service_state(_, _, _, _)),
          assertz(service_state(Endpoint, false, 0, false)) )).

% Retain the one-prompt interface for existing callers.
model_answer(Prompt, Result) :-
    ( bounded_native_text(Prompt,500,Native,N), N > 0
    -> model_chat([user(Native)], Result)
    ; Result = error(invalid_prompt) ).

model_chat(Messages, Result) :-
    ( valid_messages(Messages, JSON)
    -> setup_call_cleanup(
           message_queue_create(Queue, [max_size(1)]),
           request_model(JSON, Queue, Reply),
           message_queue_destroy(Queue)),
       model_reply(Reply, Result)
    ; Result = error(invalid_messages) ).

model_reply(answer(Native),answer(Text)) :- !,language_text(Native,Text).
model_reply(Reply,Reply).

% Only alternating user/assistant text, ending with a user turn. No system
% messages, extra JSON keys, tools, URLs or generation settings are accepted.
valid_messages(Messages, JSON) :-
    ground(Messages), is_list(Messages),
    length(Messages, Count), memberchk(Count, [1,3,5]),
    conversation(Messages, user, JSON, Size), Size =< 2000.

conversation([user(Text)], user, [_{role:"user",content:Native}], Size) :-
    bounded_native_text(Text,500,Native,Size),Size>0.
conversation([user(Text),assistant(Answer)|Rest], user,
             [_{role:"user",content:NativeText},
              _{role:"assistant",content:NativeAnswer}|JSON], Size) :-
    bounded_native_text(Text,500,NativeText,N),N>0,
    bounded_native_text(Answer,1500,NativeAnswer,M),M>0,
    conversation(Rest, user, JSON, TailSize), Size is N+M+TailSize.

message_text(Text, Limit, Size) :-
    bounded_native_text(Text,Limit,_,Size),Size>0.

request_model(Messages, Queue, Result) :-
    % Setup is protected against asynchronous cancellation: admission and
    % worker creation must finish together. The worker outlives a caller
    % abort, retaining the single inference slot until the HTTP call ends.
    setup_call_cleanup(
        start_request(Messages, Queue, Admission),
        ( Admission == started
        -> ( thread_get_message(Queue, Result, [timeout(40)])
           -> true ; Result = error(model_unavailable) )
        ; Result = Admission ),
        true).

start_request(Messages, Queue, Admission) :-
    with_mutex(model_admission,
        ( get_time(Now),
          ( \+ service_state(_, _, _, _) -> Admission = error(unavailable)
          ; service_state(_, _, _, true) -> Admission = error(unavailable)
          ; service_state(_, true, _, _) -> Admission = error(busy)
          ; service_state(_, _, Next, _), Now < Next ->
              Admission = error(rate_limited)
          ; retract(service_state(Endpoint, false, _, false)),
            Next is Now + 10,
            assertz(service_state(Endpoint, true, Next, false)),
            catch(thread_create(model_worker(Endpoint, Messages, Queue), _,
                                [detached(true)]), Error,
                  ( retractall(service_state(_, _, _, _)),
                    assertz(service_state(Endpoint, false, Next, true)),
                    throw(Error) )),
            Admission = started ) )).

model_worker(Endpoint, Messages, Queue) :-
    catch(
        ( call_with_time_limit(35, infer(Endpoint, Messages, Text))
        -> Result = answer(Text), Fault = false
        ; Result = error(model_unavailable), Fault = true ),
        _, (Result = error(model_unavailable), Fault = true)),
    with_mutex(model_admission,
        ( retract(service_state(Endpoint, true, Next, _)),
          assertz(service_state(Endpoint, false, Next, Fault)) )),
    % A timeout/error may leave backend inference running. Latch the fault
    % rather than admitting more work; recovery requires owner intervention.
    % A departed caller simply loses its reply; there is no remote send.
    catch(thread_send_message(Queue, Result, [timeout(0)]), _, true).

infer(Endpoint, Messages, Text) :-
    Payload = _{model:"smollm2:135m",
                messages:Messages,
                stream:false,
                options:_{num_ctx:1024, num_predict:80, temperature:0},
                keep_alive:"1m"},
    setup_call_cleanup(
        http_open(Endpoint, Stream,
                  [post(json(Payload)), timeout(30), redirect(false)]),
        (set_stream(Stream,encoding(octet)),read_string(Stream,16385,BytesText)),
        close(Stream)),
    string_length(BytesText,Size),Size=<16384,
    string_codes(BytesText,Bytes),string_bytes(Raw,Bytes,utf8),
    atom_json_dict(Raw, Response, []),
    get_dict(done, Response, true),
    get_dict(message, Response, Message),
    get_dict(content, Message, Text),
    string(Text), string_length(Text, Length), Length =< 4000.
