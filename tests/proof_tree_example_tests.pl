:- ['../load.pl'].
:- use_module(library(plunit)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(socket)).
:- load_files(proof_example:'../examples/actors/18 proof-trees.pl', []).

:- begin_tests(proof_tree_example).

test(local_answer_and_proof) :-
    findall(Who-Proof, proof_example:prove(mortal(Who), Proof), Answers),
    assertion(Answers == [socrates-mortal(socrates)/(human(socrates)/true)]).

test(conjunction) :-
    proof_example:prove((human(socrates), mortal(socrates)), Proof),
    assertion(Proof == (human(socrates)/true,
                        mortal(socrates)/(human(socrates)/true))).

test(no_proof, [fail]) :- proof_example:prove(mortal(plato), _).

test(isobase_source_loading_and_nested_provenance) :-
    tcp_socket(Socket), tcp_bind(Socket, Port), tcp_close_socket(Socket),
    setup_call_cleanup(
        node(Port, [auth(open), profile(stateless), sandbox(blacklist)]),
        check_remote_proofs(Port),
        http_stop_server(Port, [])).

:- end_tests(proof_tree_example).

check_remote_proofs(Port) :-
    format(atom(URI), 'http://localhost:~d', [Port]),
    read_file_to_string('examples/actors/18 proof-trees.pl', Source, []),
    findall(Who-Proof,
        rpc(URI, prove(mortal(Who), Proof), [src_text(Source)]), Local),
    assertion(Local == [socrates-mortal(socrates)/(human(socrates)/true)]),
    % Both HTTP hops use a disposable node, with a separate knowledge base
    % for each call. No public service or deployment fixture is required.
    Facts = [human(plato), human(aristotle)],
    Rules = [(mortal(X) :- human(X)), human(socrates),
             (human(X) :- rpc(URI, human(X), [src_list(Facts)]))],
    findall(Who-Proof,
        proof_example:prove(rpc(URI, mortal(Who), [src_list(Rules)]), Proof),
        Answers),
    assertion(Answers == [
        socrates-((mortal(socrates)@URI)/(human(socrates)/true)),
        plato-((mortal(plato)@URI)/(human(plato)/((human(plato)@URI)/true))),
        aristotle-((mortal(aristotle)@URI)/(human(aristotle)/((human(aristotle)@URI)/true)))
    ]).
