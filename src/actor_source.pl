:- module(actor_source, [
    prepare_actor_module/3
]).

/** <module> Actor Source Preparation

Actor-specific source/module setup extracted from `actor.pl`.
*/

:- use_module(library(modules)).
:- use_module(library(option)).
:- use_module(actor_io_support, [
    actor_io_prelude_text/1,
    actor_public_guard_prelude_text/1
]).
:- use_module(node_execution_context, [current_public_execution_profile/1]).
:- use_module(node_runtime_state, [current_node_value/2]).
:- use_module(source_loader, [
    source_options/3,
    load_sources/2
]).


%!  prepare_actor_module(+Module, +GoalModule, +Options) is det.
prepare_actor_module(Module, GoalModule, Options) :-
    delete_import_module(Module, user),
    add_import_module(Module, GoalModule, start),
    import_actor_api(Module),
    import_node_shared_db(Module),
    import_statechart_api(Module),
    configure_actor_operators(Module),
    option(source_module(SourceModule), Options, GoalModule),
    prepare_runtime_source_options(SourceModule, Options, PreparedOptions),
    inject_actor_io_prelude(PreparedOptions, WithIOPrelude),
    inject_public_runtime_guards(WithIOPrelude, EffectiveOptions),
    source_options(EffectiveOptions, SourceModule, SourceOptions),
    load_sources(Module, SourceOptions),
    restore_shadowed_shared_db_imports(Module),
    restore_runtime_imports(Module, GoalModule).


restore_runtime_imports(Module, GoalModule) :-
    add_import_module(Module, GoalModule, start),
    import_actor_api(Module),
    import_node_shared_db(Module),
    import_statechart_api(Module).


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
    (   current_node_value(shared_db_module, SharedModule)
    ->  true
    ;   SharedModule = node_shared_db_runtime
    ),
    (   current_module(SharedModule)
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
    ActorModule = actor,
    (   current_module(ActorModule)
    ->  add_import_module(Module, ActorModule, start)
    ;   true
    ).


import_node_shared_db(Module) :-
    (   current_node_value(shared_db_module, SharedModule0)
    ->  SharedModule = SharedModule0
    ;   SharedModule = node_shared_db_runtime
    ),
    (   current_module(SharedModule)
    ->  add_import_module(Module, SharedModule, start)
    ;   true
    ).


import_statechart_api(Module) :-
    StatechartModule = statechart_actor,
    (   current_module(StatechartModule)
    ->  add_import_module(Module, StatechartModule, start)
    ;   true
    ).


configure_actor_operators(Module) :-
    Module:op(800, xfx, !),
    Module:op(200, xfx, @),
    Module:op(1000, xfy, if).

inject_actor_io_prelude(Options0, [load_text(Prelude)|Options0]) :-
    actor_io_prelude_text(Prelude).

inject_public_runtime_guards(Options0, [load_text(Prelude)|Options0]) :-
    current_public_execution_profile(_),
    !,
    actor_public_guard_prelude_text(Prelude).
inject_public_runtime_guards(Options, Options).

prepare_runtime_source_options(SourceModule, Options0, Options) :-
    (   current_public_execution_profile(Profile),
        current_predicate(node_sandbox:sandbox_prepare_source_options/4)
    ->  node_sandbox:sandbox_prepare_source_options(Profile, SourceModule,
                                                    Options0, Options)
    ;   Options = Options0
    ).
