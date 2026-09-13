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

:- use_module('tiers/node/multi_node_harness').
:- begin_tests(shared_proof_tree).

test(shared_databases_ship_only_interpreter) :-
    with_test_nodes([node_spec(proof_leaf, [auth(open), profile(stateless),
        sandbox(blacklist), load_shared_db_text("human(plato). human(aristotle).")])],
      (nb_getval(node_url_proof_leaf, Leaf),
       format(string(Source),
          'mortal(X):-human(X). human(socrates). human(X):-rpc(~q,human(X)).', [Leaf]),
       with_test_nodes([node_spec(proof_root, [auth(open), profile(stateless),
           sandbox(blacklist), load_shared_db_text(Source)])],
         (nb_getval(node_url_proof_root, Root),
          findall(Who-Proof, proof_example:prove(rpc(Root,mortal(Who)),Proof), Answers),
          assertion(Answers == [
            socrates-((mortal(socrates)@Root)/(human(socrates)/true)),
            plato-((mortal(plato)@Root)/(human(plato)/((human(plato)@Leaf)/true))),
            aristotle-((mortal(aristotle)@Root)/(human(aristotle)/((human(aristotle)@Leaf)/true)))
          ])
         )))).

test(call_nth_and_clause_guards) :-
    with_test_nodes([node_spec(guard, [auth(open), profile(stateless), sandbox(blacklist),
                         load_shared_db_text("human(socrates).")])],
      (nb_getval(node_url_guard, URI),
       findall(X-N,rpc(URI,call_nth(member(X,[a,b]),N)),Answers),
       assertion(Answers == [a-1,b-2]),
       forall(member(Goal,[call_nth(halt,1),(G=halt,call_nth(G,1)),
                          clause(rpc(_,_,_),_), clause(time(_),_),
                          (H=node:shared_db(_),clause(H,_))]),
         (catch((rpc(URI,Goal), Result=unexpected_success), Error, Result=error(Error)),
          assertion(Result = error(_)))),
       findall(B,rpc(URI,clause(p(_),B),[src_text("p(X):-call_nth(member(X,[a,b]),1).")]),Bodies),
       assertion(Bodies = [call_nth(member(_,[a,b]),1)])
      )).

test(shared_inspection_shadowing_and_mutation) :-
    forall(member(Prefix,["", ":- dynamic human/1. "]),
      (string_concat(Prefix,"human(socrates).",Shared),
       with_test_nodes([node_spec(inspect, [auth(open), profile(stateless), sandbox(blacklist),
                             load_shared_db_text(Shared)])],
         (nb_getval(node_url_inspect,URI),
          findall(X-B,rpc(URI,clause(human(X),B)),SharedClauses),
          assertion(SharedClauses == [socrates-true]),
          findall(X-B,rpc(URI,clause(human(X),B),[src_text("human(local).")]),LocalClauses),
          assertion(LocalClauses == [local-true]),
          forall(member(Goal,[assertz(human(fake)),retractall(human(_))]),
            (catch((rpc(URI,Goal),Result=unexpected_success),Error,Result=error(Error)),
             assertion(Result=error(_)))),
          findall(X,rpc(URI,human(X)),Humans),
          assertion(Humans == [socrates])
         )))).

:- end_tests(shared_proof_tree).
