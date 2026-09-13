:- ['../load.pl'].
:- use_module(library(plunit)).
:- begin_tests(rpc_source_options).
source_terms(Options,Terms) :-
    isolation:load_options_text(user,Options,Text),
    setup_call_cleanup(open_string(Text,Stream),read_terms(Stream,Terms),close(Stream)).
read_terms(Stream,Terms) :-
    read_term(Stream,T,[]),
    (T==end_of_file->Terms=[];Terms=[T|Rest],read_terms(Stream,Rest)).
test(text_order) :-
    source_terms([src_text('p(a).'),src_text('p(b).')],Terms),
    assertion(Terms == [p(a),p(b)]).
test(mixed_order) :-
    source_terms([src_list([p(a),p(b)]),src_text('p(c).'),src_list([p(d)])],Terms),
    assertion(Terms == [p(a),p(b),p(c),p(d)]).
test(empty_parts) :-
    source_terms([src_text(''),src_list([p(a)]),src_list([]),src_text('p(b).')],Terms),
    assertion(Terms == [p(a),p(b)]).
:- end_tests(rpc_source_options).
