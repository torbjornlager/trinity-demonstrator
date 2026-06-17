:- module(isolation,
   [ prepare_actor_module/3,    % +Module, +GoalModule, +Options
     spawn_body/6,              % +Pid, :Goal, +Options, :OnReady, :OnPrepError, :Runner
     actor_module/2,            % +Pid, -Module
     pid_module/2,              % +LocalPid, -Module
     prepared_goal/3,           % +Module, +Goal0, -Goal
     consult_load_list/1,       % +ListOfTerms
     consult_load_list/2,       % +ListOfTerms, +Module
     listing_private/0,         %
     listing_private/1,         % +Pid

     source_options/3,          % +Options, +GoalModule, -SourceOptions
     rewrite_source_options/3,  % +Options, +GoalModule, -Options
     load_sources/2,            % +Module, +Sources
     load_source_text/3,        % +Src, +Module, +SourceId
     load_source_uri/3,         % +URI, +Module, +SourceId
     source_id/3,               % +Module, +Index, -SourceId
     load_option_text/3,        % +GoalModule, +Option, -Text
     load_options_text/3        % +GoalModule, +Options, -SourceText
   ]).

/** <module> Per-Actor Module Isolation (layer 1)

Temporary-module isolation for actors: each actor gets a private module
where its `load_text/1`, `load_list/1`, `load_uri/1`, and
`load_predicates/1` sources are loaded, importing the actor API (and,
on a node, the shared database) through the module import chain.

Extracted from the demonstrator's actor_source.pl + source_loader.pl,
plus the module-coupled actor builtins from actor.pl
(`consult_load_list`, `listing_private`).  Layer 1 imports layer 0
(`actors`) — allowed by the layering rule (imports only go downward);
the actor I/O prelude and private-listing builtins are inherently
actor-coupled.

## Hooks (multifile; no clauses here; absence = stand-alone defaults)

  - prepare_module(+Module, +GoalModule, +Options): extend the fresh
    actor module (extra imports, operators).  All solutions are run.
    The behaviours layer adds its statechart API import here; the
    distribution layer adds the `@`/2 operator.
  - prepare_goal(+Module, +Goal0, -Goal): rewrite the start goal just
    before execution (the node layer's public-profile guard).  First
    solution wins; default identity.
  - prepare_source_options(+SourceModule, +Options0, -Options):
    caller-supplied load options pass through here before loading (the
    node layer's sandbox vetting of load_text/load_uri).  First
    solution wins; default identity.
  - extra_prelude_text(+Options, -Text): additional prelude sources to
    load before the actor I/O prelude (the node layer's public runtime
    guards).  All solutions are collected.
  - rewrite_source_text(+Module, +Source0, -Source): rewrite source
    text before it is loaded (blacklist guard).  First solution wins;
    default identity.
  - source_text_guard_active: when true, load_uri fetches the source as
    text (so rewrite_source_text/3 applies) instead of streaming it.
  - shared_database_module(-SharedModule): the node layer names the
    module holding the shared database; actor modules import it and
    empty dynamic shadows of its predicates are repaired after load.
*/

:- use_module(library(modules)).
:- use_module(library(option)).
:- use_module(library(memfile)).
:- use_module(actors, [
    self/1,
    terminal_output/1
]).
%  Sibling-layer internal access (deliberately NOT part of actors'
%  export surface): pid localization, liveness, namespace visibility,
%  and the main-pid check are read via explicitly qualified calls —
%  actors:pid_local/2, actors:resolve_thread/2,
%  actors:actor_in_current_namespace/1, actors:is_main_pid/1.
:- use_module(actor_io_support, [
    actor_io_prelude_text/1
]).
:- use_module(source_utils, [
    terms_to_source/2,
    predicates_to_source/3,
    text_to_string/2,
    uri_atom/2,
    open_source_uri/2,
    uri_to_source/2,
    append_source_text/3
]).

:- multifile
    prepare_module/3,
    prepare_goal/3,
    prepare_source_options/3,
    extra_prelude_text/2,
    rewrite_source_text/3,
    source_text_guard_active/0,
    shared_database_module/1.

:- meta_predicate
    spawn_body(+, :, +, 0, 1, 1),
    consult_load_list(:).


                /*******************************
                *      ACTOR SPAWN BODY        *
                *******************************/

%!  spawn_body(+Pid, :Goal, +Options, :OnReady, :OnPrepError, :Runner) is det.
%
%   The child-side start sequence for an isolated actor; the
%   composition layer forwards `actors:hook_start_body/6` here (the
%   signatures match argument for argument):
%
%     1. create the actor's temporary module,
%     2. prepare it (imports, operators, preludes, user sources),
%     3. signal readiness — call(OnReady) on success; on a preparation
%        error E call(OnPrepError, E), then call(OnReady), then rethrow
%        (the demonstrator's start_error-before-initialized protocol),
%     4. run the goal in the module via call(Runner, Module:Goal),
%        after applying the prepare_goal/3 hook.
%
%   The temporary module is destroyed when the actor terminates.
spawn_body(Pid, Goal, Options, OnReady, OnPrepError, Runner) :-
    strip_module(Goal, GoalModule0, Plain),
    normalize_goal_module(GoalModule0, Plain, GoalModule),
    actors:pid_local(Pid, LocalPid),
    pid_module(LocalPid, Module),
    in_temporary_module(
        Module,
        prepare_and_signal(Module, GoalModule, Options, OnReady, OnPrepError),
        execute_in_module(Module, Plain, Runner)).

prepare_and_signal(Module, GoalModule, Options, OnReady, OnPrepError) :-
    catch(
        prepare_actor_module(Module, GoalModule, Options),
        PrepError,
        (   call(OnPrepError, PrepError),
            call(OnReady),
            throw(PrepError)
        )
    ),
    call(OnReady).

execute_in_module(Module, Plain, Runner) :-
    prepared_goal(Module, Plain, Rewritten),
    call(Runner, Module:Rewritten).

%!  prepared_goal(+Module, +Goal0, -Goal) is det.
%
%   Apply the prepare_goal/3 hook (the node layer's per-goal guard);
%   identity when no clause claims the goal.  Exported because the
%   toplevel layer applies the same guard to every '$call' goal, not
%   just spawn-time start goals.
prepared_goal(Module, Goal0, Goal) :-
    (   prepare_goal(Module, Goal0, Goal1)
    ->  Goal = Goal1
    ;   Goal = Goal0
    ).

%!  normalize_goal_module(+GoalModule0, +PlainGoal, -GoalModule) is det.
%
%   When the caller module is `actors` but the predicate actually
%   belongs to `user`, use `user` as the import source.
normalize_goal_module(actors, Plain, user) :-
    \+ predicate_in_module(actors, Plain),
    !.
normalize_goal_module(Module, _, Module).

predicate_in_module(Module, Goal) :-
    callable(Goal),
    functor(Goal, Name, Arity),
    current_predicate(Module:Name/Arity).


                /*******************************
                *      MODULE PREPARATION      *
                *******************************/

%!  pid_module(+LocalPid, -Module) is det.
%
%   Map a local actor pid to the private module where its code lives.
%   The main/REPL thread maps to `user`, as in the demonstrator.
pid_module(main, user) :- !.
pid_module(Pid, user) :-
    actors:is_main_pid(Pid),
    !.
pid_module(actor(N), Module) :-
    !,
    format(atom(Module), 'actor_~w', [N]).
pid_module(Pid, Module) :-
    format(atom(Module), 'actor_~w', [Pid]).

%!  actor_module(+Pid, -Module) is det.

actor_module(Pid, Module) :-
    actors:pid_local(Pid, LocalPid),
    pid_module(LocalPid, Module).


%!  prepare_actor_module(+Module, +GoalModule, +Options) is det.
prepare_actor_module(Module, GoalModule, Options) :-
    delete_import_module(Module, user),
    add_import_module(Module, GoalModule, start),
    import_actor_api(Module),
    import_shared_db(Module),
    forall(prepare_module(Module, GoalModule, Options), true),
    configure_actor_operators(Module),
    option(source_module(SourceModule), Options, GoalModule),
    prepare_runtime_source_options(SourceModule, Options, PreparedOptions),
    inject_actor_io_prelude(PreparedOptions, WithIOPrelude),
    inject_extra_preludes(WithIOPrelude, EffectiveOptions),
    source_options(EffectiveOptions, SourceModule, SourceOptions),
    load_sources(Module, SourceOptions),
    restore_shadowed_shared_db_imports(Module),
    restore_runtime_imports(Module, GoalModule, Options).


restore_runtime_imports(Module, GoalModule, Options) :-
    add_import_module(Module, GoalModule, start),
    import_actor_api(Module),
    import_shared_db(Module),
    forall(prepare_module(Module, GoalModule, Options), true).


%!  restore_shadowed_shared_db_imports(+Module) is det.
%
%   After loading actor source, remove any empty dynamic predicates that
%   were created by `:- dynamic` declarations in the scratch buffer and
%   that shadow predicates actually defined in the shared DB module.
%
%   This happens because SWI-Prolog's `:- dynamic` directive, when run in
%   a module that already has the predicate imported, pulls the predicate
%   out of the import chain and creates a local empty version.  Once
%   abolished, the predicate is resolved through the import chain again and
%   `clause/2` returns the real shared-DB clauses – which is what bespoke
%   meta-interpreters (e.g. proof-tree builders) require.
restore_shadowed_shared_db_imports(Module) :-
    (   shared_database_module(SharedModule),
        current_module(SharedModule)
    ->  forall(
            shadowing_empty_dynamic(Module, SharedModule, Name, Arity),
            abolish(Module:Name/Arity)
        )
    ;   true
    ).

shadowing_empty_dynamic(Module, SharedModule, Name, Arity) :-
    current_predicate(Module:Name/Arity),
    atom(Name),
    functor(Head, Name, Arity),
    predicate_property(Module:Head, dynamic),
    \+ predicate_property(Module:Head, imported_from(_)),
    predicate_property(Module:Head, number_of_clauses(0)),
    predicate_property(SharedModule:Head, defined),
    \+ predicate_property(SharedModule:Head, imported_from(_)).


import_actor_api(Module) :-
    ActorModule = actors,
    (   current_module(ActorModule)
    ->  add_import_module(Module, ActorModule, start)
    ;   true
    ).


import_shared_db(Module) :-
    (   shared_database_module(SharedModule),
        current_module(SharedModule)
    ->  add_import_module(Module, SharedModule, start)
    ;   true
    ).


configure_actor_operators(Module) :-
    Module:op(800, xfx, !),
    Module:op(1000, xfy, if).

inject_actor_io_prelude(Options0, [load_text(Prelude)|Options0]) :-
    actor_io_prelude_text(Prelude).

inject_extra_preludes(Options0, Options) :-
    findall(load_text(Text), extra_prelude_text(Options0, Text), Extras),
    append(Extras, Options0, Options).

prepare_runtime_source_options(SourceModule, Options0, Options) :-
    (   prepare_source_options(SourceModule, Options0, Options1)
    ->  Options = Options1
    ;   Options = Options0
    ).


                /*******************************
                *        SOURCE LOADING        *
                *******************************/

%!  source_options(+Options, +GoalModule, -SourceOptions) is det.
%
%   Extract and normalize source-loading options from an option list.
source_options([], _, []).
source_options([Option|Options], GoalModule, SourceOptions) :-
    normalize_source_option(Option, GoalModule, SourceOption),
    !,
    SourceOptions = [SourceOption|Rest],
    source_options(Options, GoalModule, Rest).
source_options([Option|_], _, _) :-
    removed_source_option(Option),
    !,
    throw(error(domain_error(load_source_option, Option),
                context(source_loader:source_options/3,
                        'src_* options are no longer supported; use load_* options'))).
source_options([_|Options], GoalModule, SourceOptions) :-
    source_options(Options, GoalModule, SourceOptions).


%!  rewrite_source_options(+Options, +GoalModule, -RewrittenOptions) is det.
%
%   Rewrite only source-related options in-place while preserving all other
%   options and their order.
rewrite_source_options([], _, []).
rewrite_source_options([Option0|Options0], GoalModule, [Option|Options]) :-
    (   normalize_source_option(Option0, GoalModule, Option)
    ->  true
    ;   Option = Option0
    ),
    rewrite_source_options(Options0, GoalModule, Options).


normalize_source_option(load_text(Text0), _, load_text(Text)) :-
    text_to_string(Text0, Text).
normalize_source_option(load_uri(URI), _, load_uri(URI)).
normalize_source_option(load_list(Terms), _, load_text(Source)) :-
    terms_to_source(Terms, Source).
normalize_source_option(load_predicates(PIs), GoalModule, load_text(Source)) :-
    predicates_to_source(GoalModule, PIs, Source).

removed_source_option(src_text(_)).
removed_source_option(src_uri(_)).
removed_source_option(src_list(_)).
removed_source_option(src_predicates(_)).


%!  load_sources(+Module, +Sources) is det.
load_sources(Module, Sources) :-
    load_sources(Module, Sources, 1).

load_sources(_, [], _).
load_sources(Module, [Source|Sources], Index0) :-
    source_id(Module, Index0, SourceId),
    load_source(Module, Source, SourceId),
    Index is Index0 + 1,
    load_sources(Module, Sources, Index).


%!  source_id(+Module, +Index, -SourceId) is det.
source_id(Module, Index, SourceId) :-
    format(atom(SourceId), '~w_source_~d', [Module, Index]).


load_source(Module, load_text(Source), SourceId) :-
    load_source_text(Source, Module, SourceId).
load_source(Module, load_uri(URI), SourceId) :-
    load_source_uri(URI, Module, SourceId).


%!  load_source_text(+Src, +Module, +SourceId) is det.
load_source_text(Src, Module, SourceId) :-
    text_to_string(Src, Source0),
    (   rewrite_source_text(Module, Source0, Source)
    ->  true
    ;   Source = Source0
    ),
    setup_call_cleanup(
        open_chars_stream(Source, Stream),
        load_files(Module:SourceId,
                   [ stream(Stream),
                     module(Module),
                     silent(true)
                   ]),
        close(Stream)).


%!  load_source_uri(+URI0, +Module, +SourceId) is det.
load_source_uri(URI0, Module, SourceId) :-
    uri_atom(URI0, URI),
    (   source_text_guard_active
    ->  uri_to_source(URI, Source0),
        load_source_text(Source0, Module, SourceId)
    ;   setup_call_cleanup(
            open_source_uri(URI, Stream),
            load_files(Module:SourceId,
                       [ stream(Stream),
                         module(Module),
                         silent(true)
                       ]),
            close(Stream))
    ).


%!  load_option_text(+GoalModule, +Option, -Text) is semidet.
load_option_text(_, load_text(Text0), Text) :-
    text_to_string(Text0, Text).
load_option_text(_, load_list(Terms), Text) :-
    terms_to_source(Terms, Text).
load_option_text(GoalModule, load_predicates(PIs), Text) :-
    predicates_to_source(GoalModule, PIs, Text).
load_option_text(_, load_uri(URI), Text) :-
    uri_to_source(URI, Text).


%!  load_options_text(+GoalModule, +Options, -SourceText) is det.
%
%   Convert all load_* options in order into one source text string.
load_options_text(GoalModule, Options, SourceText) :-
    findall(Text,
            ( member(Option, Options),
              load_option_text(GoalModule, Option, Text)
            ),
            Texts),
    foldl(append_source_text, Texts, "", SourceText).


                /*******************************
                *   PRIVATE DATABASE BUILTINS  *
                *******************************/

%!  consult_load_list(+ListOfTerms) is det.
%!  consult_load_list(+ListOfTerms, +Module) is det.
%
%   Consult a list of clauses in the relevant module.

consult_load_list(ListSpec) :-
    strip_module(ListSpec, _, List),
    self(Pid),
    actor_module(Pid, Module),
    consult_load_list(List, Module).

consult_load_list(List, Module) :-
    terms_to_source(List, Source),
    load_source_text(Source, Module, load_list).

%!  listing_private is det.
%!  listing_private(+Pid) is det.
%
%   Emit a textual listing of predicates defined in the relevant actor's
%   private module. Imported predicates and the injected actor I/O wrapper
%   predicates are excluded. In public execution contexts, `listing_private/1`
%   is namespace-scoped so clients can only inspect their own actors.
listing_private :-
    self(Pid),
    actor_module(Pid, Module),
    emit_private_listing(Module).

listing_private(Pid) :-
    listing_target_module(Pid, Module),
    emit_private_listing(Module).

listing_target_module(Pid0, Module) :-
    (   actors:pid_local(Pid0, LocalPid)
    ->  true
    ;   throw(error(existence_error(actor, Pid0),
                    context(actor:listing_private/1,
                            'actor pid is not local to this node')))
    ),
    (   actors:resolve_thread(LocalPid, _)
    ->  true
    ;   throw(error(existence_error(actor, Pid0),
                    context(actor:listing_private/1,
                            'unknown or expired actor pid')))
    ),
    require_listing_visibility(LocalPid, Pid0),
    pid_module(LocalPid, Module).

require_listing_visibility(LocalPid, Pid0) :-
    (   actors:actor_in_current_namespace(LocalPid)
    ->  true
    ;   throw(error(permission_error(access, actor_private_database, Pid0),
                    context(actor:listing_private/1,
                            'actor pid is not visible in current public namespace')))
    ).

emit_private_listing(Module) :-
    findall(Name/Arity,
            private_listing_predicate(Module, Name, Arity),
            PredicateIndicators0),
    sort(PredicateIndicators0, PredicateIndicators),
    new_memory_file(MemoryFile),
    setup_call_cleanup(
        open_memory_file(MemoryFile, write, Stream),
        portray_private_listing(Stream, Module, PredicateIndicators),
        close(Stream)
    ),
    memory_file_to_string(MemoryFile, Text),
    free_memory_file(MemoryFile),
    (   Text == ""
    ->  true
    ;   terminal_output(Text)
    ).

private_listing_predicate(Module, Name, Arity) :-
    current_predicate(Module:Name/Arity),
    \+ private_listing_hidden(Name/Arity),
    functor(Head, Name, Arity),
    \+ predicate_property(Module:Head, imported_from(_)),
    predicate_property(Module:Head, number_of_clauses(ClauseCount)),
    ClauseCount > 0.

portray_private_listing(_Stream, _Module, []) :-
    !.
portray_private_listing(Stream, Module, PredicateIndicators) :-
    nl(Stream),
    portray_private_listing_items(Stream, Module, PredicateIndicators).

portray_private_listing_items(Stream, Module, [Name/Arity]) :-
    !,
    portray_private_predicate(Stream, Module, Name, Arity).
portray_private_listing_items(Stream, Module, [Name/Arity|Rest]) :-
    portray_private_predicate(Stream, Module, Name, Arity),
    nl(Stream),
    portray_private_listing_items(Stream, Module, Rest).

portray_private_predicate(Stream, Module, Name, Arity) :-
    functor(Head, Name, Arity),
    forall(clause(Module:Head, Body),
           portray_private_clause(Stream, Head, Body)).

portray_private_clause(Stream, Head, true) :-
    !,
    system:portray_clause(Stream, Head).
portray_private_clause(Stream, Head, Body) :-
    system:portray_clause(Stream, (Head :- Body)).

private_listing_hidden(display/1).
private_listing_hidden(format/1).
private_listing_hidden(format/2).
private_listing_hidden(listing/0).
private_listing_hidden(listing/1).
private_listing_hidden(nl/0).
private_listing_hidden(print/1).
private_listing_hidden(time/1).
private_listing_hidden(write/1).
private_listing_hidden(write_canonical/1).
private_listing_hidden(write_term/2).
private_listing_hidden(writeq/1).
private_listing_hidden(writeln/1).
private_listing_hidden(actor_time_output/1).
private_listing_hidden(actor_time_string/2).
private_listing_hidden(format_to_atom_safe/2).
private_listing_hidden(reject_format_call_specifier/1).
private_listing_hidden('$parent'/1).
