:- module(pinned_swi_bootstrap, [check_origins/0]).
:- use_module(library(filesex)).
:- prolog_load_context(directory, Here),
   getenv('TRINITY_PINNED_SWI_ROOT', Native),
   directory_file_path(Native, prolog, Prolog),
   asserta(user:file_search_path(library, Prolog)),
   directory_file_path(Here, '../prolog', LocalProlog),
   nb_setval(pinned_native_prolog, Prolog),
   nb_setval(pinned_local_prolog, LocalProlog).
:- user:use_module(library(web_prolog)).
:- initialization((catch(check_origins, Error,
                         (print_message(error,Error),halt(2)))
                    -> true ; halt(2))).

% Mandatory roots and every loaded same-named native module must originate
% in the selected package. Neither a global pack nor retained local copies
% may silently satisfy an import.
check_origins :-
    nb_getval(pinned_native_prolog, Prolog),
    forall(member(Module-Rel, [web_prolog-'web_prolog.pl',
                              node-'web_prolog/node.pl',
                              actors-'web_prolog/actors.pl',
                              isolation-'web_prolog/isolation.pl',
                              sxml_schema-'web_prolog/wasm/sxml_schema.pl']),
           (module_property(Module,file(File)),directory_file_path(Prolog,Rel,Expected),
            (same_file(File,Expected) -> true ; throw(error(native_origin_mismatch(Module,File,Expected),_))))),
    directory_file_path(Prolog, 'web_prolog/*.pl', Pattern),
    expand_file_name(Pattern, Sources),
    forall((member(Expected,Sources),
            setup_call_cleanup(open(Expected,read,Stream),
                               read_term(Stream,First,[]),close(Stream)),
            First = (:- module(Module,_)),
            module_property(Module,file(File))),
           (same_file(File,Expected) -> true ; throw(error(native_origin_mismatch(Module,File,Expected),_)))),
    nb_getval(pinned_local_prolog, Local),
    forall(source_file(File),
           (relative_file_name(File,Local,Rel),
            (sub_atom(Rel,0,_,_,'web_prolog/') ; Rel=='web_prolog.pl')
            -> throw(error(colocated_native_source_loaded(File),_)) ; true)).
