:- use_module(library(ssl)).
:- use_module(library(crypto)).
run :-
 ssl_context(client,_,[]),
 crypto_data_hash('acceptance',Hash,[algorithm(sha256)]),
 format('ssl_context_ok crypto_hash(~q).~n',[Hash]),
 forall(current_foreign_library(F,_),format('foreign(~q).~n',[F])),
 current_prolog_flag(home,Home),sub_atom(Home,_,_,_,'/install/'),
 format('home(~q).~n',[Home]).
