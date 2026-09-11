:- module(io_ack_probe, [main/0]).

:- use_module('../prolog/web_prolog/node', []).
:- use_module('../prolog/web_prolog/distribution', []).
:- use_module('../prolog/web_prolog/remote_protocol', []).
:- use_module(library(http/json)).
:- use_module(library(lists)).

% Benchmark only. The async branch reproduces the pre-ack transport path;
% it is deliberately not installed as a runtime option or hook.
main :-
    current_prolog_flag(argv, Args),
    ( Args = [server, PortAtom]
    -> atom_number(PortAtom, Port), server(Port)
    ; Args = [memory, CountAtom]
    -> atom_number(CountAtom, Count), memory(Count)
    ; Args = [client, Mode, URL, WritersAtom, LinesAtom, BatchAtom]
    -> maplist(atom_number, [WritersAtom, LinesAtom, BatchAtom],
                           [Writers, Lines, Batch]),
       client(Mode, URL, Writers, Lines, Batch)
    ; throw(error(domain_error(benchmark_arguments, Args), _))
    ).

emit(Dict) :- json_write_dict(current_output, Dict, [width(0)]), nl, flush_output.

% Isolate the retained queue + nonce + pending-record cost from the much
% larger pre-existing actor threads/stacks. These are the actual allocation
% operations used by remote_request_io/2, held live for an external RSS read.
memory(Count) :-
    statistics(threads, Before), emit(_{ready:true, threads:Before}), read(go),
    forall(between(1, Count, _),
        ( message_queue_create(Queue),
          distribution:fresh_io_endpoint_token(IdAtom), atom_string(IdAtom, Id),
          assertz(distribution:pending_io_request(benchmark_memory, Id, Queue)) )),
    statistics(threads, After), emit(_{ready:true, threads:After}), read(stop),
    forall(retract(distribution:pending_io_request(benchmark_memory, _, Queue)),
           message_queue_destroy(Queue)).

server(Port) :-
    node:node(Port, [profile(actor), auth(open),
                              max_ws_commands_per_window(1000000)]),
    message_queue_create(Terminal),
    assertz(distribution:io_endpoint_target(benchmark_terminal, Terminal)),
    thread_create(collect(Terminal, 0, 0), _, [detached(true)]),
    emit(_{ready:true}),
    server_commands(Terminal).

server_commands(Terminal) :-
    read(Command),
    ( Command == stop -> true
    ; memberchk(Command, [reset, snapshot]),
      thread_self(Main),
      thread_send_message(Terminal, stats(Command, Main)),
      thread_get_message(counts(Messages, Characters)),
      statistics(process_cputime, CPU),
      emit(_{messages:Messages, characters:Characters, cpu_seconds:CPU}),
      server_commands(Terminal)
    ).

collect(Queue, Messages, Characters) :-
    thread_get_message(Queue, Message),
    ( Message = terminal_output(barrier, _) -> M1 = Messages, C1 = Characters
    ; Message = terminal_output(_, Payload)
    -> string_length(Payload, Size), M1 is Messages+1, C1 is Characters+Size
    ; Message = stats(Command, Main)
    -> thread_send_message(Main, counts(Messages, Characters)),
       ( Command == reset -> M1 = 0, C1 = 0 ; M1 = Messages, C1 = Characters )
    ),
    collect(Queue, M1, C1).

client(Mode, URL, Writers, Lines, Batch) :-
    memberchk(Mode, [ack, async]),
    0 is Lines mod (Writers*Batch),
    Calls is Lines // (Writers*Batch),
    % Exactly 64 ASCII bytes per logical line, including newline.
    Line = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.\n",
    string_length(Line, 64),
    length(Parts, Batch), maplist(=(Line), Parts), atomics_to_string(Parts, Payload),
    barrier(URL),
    write_payload(ack, URL, warmup, Payload),
    thread_self(Main),
    findall(Thread,
        ( between(1, Writers, Index),
          thread_create(writer(Main, Index, Mode, URL, Payload, Calls), Thread, []) ),
        Threads),
    emit(_{ready:true}), read(go),
    statistics(process_cputime, CPU0), get_time(T0),
    forall(member(Thread, Threads), thread_send_message(Thread, go)),
    findall(Samples,
        ( between(1, Writers, _), thread_get_message(done(Result, Samples)),
          ( Result == true -> true ; throw(Result) ) ), SampleLists),
    get_time(Submitted),
    % A final acknowledged barrier on the SAME connection measures completed
    % async delivery. Ack writes already have this guarantee individually.
    ( Mode == async -> barrier(URL) ; true ),
    get_time(Delivered), statistics(process_cputime, CPU1),
    forall(member(Thread, Threads), thread_join(Thread, true)),
    append(SampleLists, Samples), msort(Samples, Sorted),
    percentile(Sorted, 0.50, P50), percentile(Sorted, 0.95, P95),
    SubmitMS is (Submitted-T0)*1000, DeliveryMS is (Delivered-T0)*1000,
    CPUMS is (CPU1-CPU0)*1000,
    aggregate_all(count, distribution:pending_io_request(_, _, _), Pending),
    emit(_{submit_ms:SubmitMS, delivered_ms:DeliveryMS, client_cpu_ms:CPUMS,
           write_p50_ms:P50, write_p95_ms:P95, pending_requests:Pending}),
    read(stop).

writer(Main, Index, Mode, URL, Payload, Calls) :-
    thread_get_message(go),
    catch((findall(MS,
        ( between(1, Calls, _), get_time(T0),
          write_payload(Mode, URL, Index, Payload),
          get_time(T1), MS is (T1-T0)*1000 ), Samples), Result = true),
        Error, Result = Error),
    thread_send_message(Main, done(Result, Samples)).

write_payload(ack, URL, Index, Payload) :-
    distribution:route_io_endpoint(benchmark_terminal, URL,
                                   terminal_output(Index, Payload)).
write_payload(async, URL, Index, Payload) :-
    remote_protocol:term_to_wire_atom(terminal_output(Index, Payload), Message),
    distribution:remote_send_command(URL, json{
        command:io_request, token:benchmark_terminal, message:Message
    }).

barrier(URL) :- write_payload(ack, URL, barrier, "").

percentile(Sorted, Fraction, Value) :-
    length(Sorted, N), Index is max(1, ceiling(N*Fraction)), nth1(Index, Sorted, Value).
