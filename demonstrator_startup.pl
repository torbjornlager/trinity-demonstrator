:- module(demonstrator_startup,[load_native/1]).
:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module(library(http/json)).
:- use_module(library(filesex)).
:- dynamic root/1.
:- prolog_load_context(directory,Root),assertz(root(Root)).

load_native(Into) :-
    (getenv('WP_NATIVE_MODE',Mode0) -> Mode=Mode0 ; Mode=pinned),
    ( Mode==legacy -> load_legacy(Into)
    ; Mode==pinned -> load_pinned
    ; throw(error(domain_error(native_startup_mode,Mode),_)) ).

load_legacy(Into) :-
    root(Root),directory_file_path(Root,prolog,Lib),
    directory_file_path(Lib,'web_prolog.pl',Entry),
    asserta(user:file_search_path(library,Lib)),
    Into:use_module(Entry),
    module_property(web_prolog,file(Loaded)),
    (same_file(Loaded,Entry) -> true ; throw(error(native_origin_mismatch(web_prolog,Loaded,Entry),_))).

load_pinned :-
    root(Root),directory_file_path(Root,'tools/setup_swi.py',Validator),
    (getenv('WP_NATIVE_STATE',State0),State0\=='' -> absolute_file_name(State0,State)
    ; directory_file_path(Root,'.trinity/native-swi.json',State)),
    setup_call_cleanup(
      process_create(path(python3),[Validator,'--validate','--state-file',State],
                     [stdout(pipe(Out)),stderr(pipe(Err)),process(PID)]),
      (read_string(Out,_,JSON),read_string(Err,_,Diagnostic),process_wait(PID,Status)),
      (close(Out),close(Err))),
    (Status==exit(0) -> atom_json_dict(JSON,Config,[])
    ; throw(error(native_dependency_setup(Diagnostic),context(load_native/1,'Pinned setup failed before node startup')))),
    setenv('TRINITY_PINNED_SWI_ROOT',Config.native_root),
    setenv('WP_ASSET_ROOT',Config.asset_root),setenv('WP_WASM_SOURCE_DIR',Config.wasm_root),
    directory_file_path(Root,'tools/pinned_swi_bootstrap.pl',Bootstrap),
    use_module(Bootstrap,[]),pinned_swi_bootstrap:check_origins.
