:- module(node_sandbox, [
    sandbox_mode/1,
    normalize_sandbox_mode/2,
    sandbox_enabled/0,
    sandbox_check_goal/2,
    sandbox_check_goal_in_module/3,
    sandbox_check_dynamic_clause/3,
    sandbox_check_spawn_options/2,
    sandbox_check_source_text/3,
    sandbox_check_source_options/3,
    sandbox_prepare_source_options/4,
    sandbox_prepare_public_spawn/5,
    sandbox_check_goal_with_source/4,
    sandbox_check_goal_with_options/4
]).

/** <module> Node Sandbox Policy

One node-owned sandbox layer around `library(sandbox)` for all public
execution paths.
*/

:- op(800, xfx, !).
:- op(200, xfx, @).
:- op(1000, xfy, if).

:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(library(modules)).
:- use_module(library(option)).
:- use_module(library(settings)).
:- use_module(library(sandbox)).
:- use_module(library(uri)).

:- use_module(goal_walker, [walk_goal/2]).
:- use_module(node_client, [text_to_string/2]).
:- use_module(actor_source, [prepare_actor_module/3]).
:- use_module(node_runtime_state, [current_node_value/2]).
:- use_module(node_execution_context, [without_public_execution_context/1]).
:- use_module(node_input_limits, [
    current_max_load_text_bytes/1,
    check_source_text_size/2
]).
:- use_module(node_profile_policy, [
    profile_check_goal/2,
    profile_check_spawn_options/2,
    profile_check_source_text/3,
    profile_check_source_options/3
]).
:- use_module(node_builtin_policy, [
    builtin_goal_policy/3,
    builtin_family_enabled/2
]).
:- use_module(source_loader, [
    source_options/3,
    load_option_text/3
]).
:- use_module(source_utils, [
    normalize_load_uri_allowed_origins/2,
    uri_to_source_limited/3
]).

:- multifile
    sandbox:safe_primitive/1,
    sandbox:safe_meta/2.


%!  sandbox_mode(-Mode) is det.
%
%   Effective node sandbox mode. Canonical values are `off`, `whitelist`,
%   and `blacklist`. Legacy values `on`, `demo`, and `strict` are accepted
%   as aliases for `whitelist`.
sandbox_mode(Mode) :-
    (   current_node_value(sandbox, Mode1)
    ->  Mode0 = Mode1
    ;   setting(node:sandbox, Mode0)
    ),
    normalize_sandbox_mode(Mode0, Mode).


%!  normalize_sandbox_mode(+Mode0, -Mode) is det.
normalize_sandbox_mode(off, off) :-
    !.
normalize_sandbox_mode(whitelist, whitelist) :-
    !.
normalize_sandbox_mode(blacklist, blacklist) :-
    !.
normalize_sandbox_mode(on, whitelist) :-
    !.
normalize_sandbox_mode(demo, whitelist) :-
    !.
normalize_sandbox_mode(strict, whitelist) :-
    !.
normalize_sandbox_mode(Mode, _) :-
    throw(error(domain_error(node_sandbox_mode, Mode),
                context(node_sandbox:normalize_sandbox_mode/2,
                        'sandbox mode must be off, whitelist, or blacklist (on/demo/strict are accepted as aliases for whitelist)'))).

%!  sandbox_enabled is semidet.
sandbox_enabled :-
    sandbox_mode(Mode),
    Mode \== off.


%!  sandbox_check_goal(+Profile, +QualifiedGoal) is det.
%
%   Validate a goal against the active sandbox policy.
sandbox_check_goal(Profile, QualifiedGoal) :-
    must_be(callable, QualifiedGoal),
    profile_check_goal(Profile, QualifiedGoal),
    sandbox_mode(Mode),
    (   Mode == off
    ->  true
    ;   QualifiedGoal = (Module:Goal),
        atom(Module)
    ->  sandbox_check_qualified_goal(Mode, Profile, Module, Goal)
    ;   strip_module(QualifiedGoal, Module, Goal),
        sandbox_check_goal_in_module_(Mode, Profile, Module, Goal)
    ).

%!  sandbox_check_goal_in_module(+Profile, +Module, +Goal) is det.
%
%   Validate Goal as code that executes in Module. This is the internal entry
%   point for temporary actor modules created during source validation.
sandbox_check_goal_in_module(Profile, Module, Goal) :-
    must_be(atom, Module),
    must_be(callable, Goal),
    profile_check_goal(Profile, Module:Goal),
    sandbox_mode(Mode),
    (   Mode == off
    ->  true
    ;   sandbox_check_goal_in_module_(Mode, Profile, Module, Goal)
    ).

sandbox_check_qualified_goal(blacklist, Profile, Module, Goal) :-
    (   Module == actor
    ;   Module == node
    ),
    !,
    sandbox_check_goal_in_module_(blacklist, Profile, Module, Goal).
sandbox_check_qualified_goal(blacklist, _Profile, Module, Goal) :-
    throw(error(permission_error(call, sandboxed, Module:Goal),
                context(node_sandbox:sandbox_check_goal/2,
                        'top-level module-qualified goal is disabled in blacklist sandbox mode'))).
sandbox_check_qualified_goal(Mode, Profile, Module, Goal) :-
    sandbox_check_goal_in_module_(Mode, Profile, Module, Goal).

sandbox_check_goal_in_module_(Mode, Profile, Module, Goal) :-
    reject_forbidden_goal(Profile, Module, Goal),
    sandbox_enforce_goal(Mode, Module, Goal).


%!  sandbox_check_dynamic_clause(+Profile, +Module, +Clause) is det.
%
%   Validate a dynamic clause term under blacklist sandbox policy.
sandbox_check_dynamic_clause(Profile, Module, Clause) :-
    precheck_dynamic_clause_term(Profile, Module, Clause).


%!  sandbox_check_spawn_options(+Profile, +Options) is det.
%
%   Validate public spawn options that affect capability surface.
sandbox_check_spawn_options(_Profile, Options) :-
    var(Options),
    !.
sandbox_check_spawn_options(Profile, Options) :-
    must_be(list, Options),
    profile_check_spawn_options(Profile, Options),
    (   \+ sandbox_enabled
    ->  true
    ;   maplist(reject_forbidden_spawn_option(Profile), Options)
    ).


%!  sandbox_check_source_text(+Profile, +GoalModule, +SourceText) is det.
%
%   Validate source text in an isolated temporary actor module.
sandbox_check_source_text(Profile, GoalModule, SourceText0) :-
    profile_check_source_text(Profile, GoalModule, SourceText0),
    text_to_string(SourceText0, SourceText),
    (   SourceText == ""
    ->  true
    ;   \+ sandbox_enabled
    ->  true
    ;   in_temporary_module(Module,
                            sandbox_prepare_module(Module),
                            validate_and_load_source_text(Profile, Module, SourceText, sandbox_source))
    ).


%!  sandbox_check_source_options(+Profile, +GoalModule, +Options) is det.
%
%   Validate all load_* options in order.
sandbox_check_source_options(Profile, GoalModule, Options) :-
    profile_check_source_options(Profile, GoalModule, Options),
    sandbox_check_spawn_options(Profile, Options),
    (   \+ sandbox_enabled
    ->  true
    ;   in_temporary_module(Module,
                            sandbox_prepare_module(Module),
                            validate_source_options(Profile, Module, GoalModule, Options))
    ).


%!  sandbox_prepare_source_options(+Profile, +GoalModule, +Options0, -Options)
%!  is det.
%
%   Validate public source options and, in sandbox mode, materialize them to
%   `load_text/1` so the later actor/session load uses the same source text
%   that was checked here.
sandbox_prepare_source_options(Profile, GoalModule, Options0, Options) :-
    must_be(list, Options0),
    profile_check_spawn_options(Profile, Options0),
    profile_check_source_options(Profile, GoalModule, Options0),
    (   \+ sandbox_enabled
    ->  Options = Options0
    ;   in_temporary_module(Module,
                            sandbox_prepare_module(Module),
                            prepare_source_options(Profile, Module, GoalModule,
                                                   Options0, Options))
    ).


%!  sandbox_prepare_public_spawn(+Profile, +GoalModule, +Goal, +Options0, -Options)
%!  is det.
%
%   Runtime validation/materialization for public nested spawn/3 after any
%   computed source options have become concrete.
sandbox_prepare_public_spawn(Profile, GoalModule, Goal, Options0, Options) :-
    must_be(list, Options0),
    (   public_runtime_support_goal(GoalModule, Goal)
    ->  true
    ;   profile_check_goal(Profile, GoalModule:Goal)
    ),
    profile_check_spawn_options(Profile, Options0),
    profile_check_source_options(Profile, GoalModule, Options0),
    (   \+ sandbox_enabled
    ->  Options = Options0
    ;   in_temporary_module(
            Module,
            sandbox_prepare_module(Module, GoalModule),
            (
                prepare_source_options(Profile, Module, GoalModule,
                                       Options0, Options),
                (   public_runtime_support_goal(GoalModule, Goal)
                ->  true
                ;   sandbox_check_goal_in_module(Profile, Module, Goal)
                )
            )
        )
    ).

public_runtime_support_goal(actor, Goal) :-
    callable(Goal),
    functor(Goal, Name, Arity),
    public_runtime_support_goal_pi(Name/Arity).

public_runtime_support_goal_pi(remote_actor_proxy/3).
public_runtime_support_goal_pi(send_with_delay/3).


%!  sandbox_check_goal_with_source(+Profile, +GoalModule, +Goal, +SourceText) is det.
%
%   Validate source text and a goal in one isolated actor module so calls to
%   predicates defined by the provided source remain analyzable.
sandbox_check_goal_with_source(Profile, GoalModule, Goal, SourceText0) :-
    profile_check_source_text(Profile, GoalModule, SourceText0),
    profile_check_goal(Profile, Goal),
    text_to_string(SourceText0, SourceText),
    (   \+ sandbox_enabled
    ->  true
    ;   in_temporary_module(Module,
                            sandbox_prepare_module(Module),
                            (   validate_and_load_source_text(Profile, Module, SourceText, sandbox_source),
                                sandbox_check_goal_in_module(Profile, Module, Goal)
                            ))
    ).


%!  sandbox_check_goal_with_options(+Profile, +GoalModule, +Goal, +Options) is det.
%
%   Validate spawn source options and a spawn goal in one isolated actor
%   module.
sandbox_check_goal_with_options(Profile, GoalModule, Goal, Options) :-
    profile_check_spawn_options(Profile, Options),
    profile_check_source_options(Profile, GoalModule, Options),
    profile_check_goal(Profile, Goal),
    sandbox_check_spawn_options(Profile, Options),
    (   \+ sandbox_enabled
    ->  true
    ;   in_temporary_module(Module,
                            sandbox_prepare_module(Module),
                            (   validate_source_options(Profile, Module, GoalModule, Options),
                                sandbox_check_goal_in_module(Profile, Module, Goal)
                            ))
    ).


sandbox_prepare_module(Module) :-
    sandbox_prepare_module(Module, actor).

sandbox_prepare_module(Module, GoalModule) :-
    without_public_execution_context(
        prepare_actor_module(Module, GoalModule, [])
    ).


validate_source_options(Profile, Module, GoalModule, Options) :-
    prepare_source_options(Profile, Module, GoalModule, Options, _Prepared).

sandbox_source_id(Index, SourceId) :-
    format(atom(SourceId), 'sandbox_source_~d', [Index]).

prepare_source_options(Profile, Module, GoalModule, Options0, Options) :-
    prepare_source_options(Profile, Module, GoalModule, Options0, Options, 1).

prepare_source_options(_, _, _, [], [], _).
prepare_source_options(Profile, Module, GoalModule, [Option0|Options0],
                       [Option|Options], Index0) :-
    (   materialize_source_option(GoalModule, Option0, Field, SourceText)
    ->  check_source_text_size(Field, SourceText),
        sandbox_source_id(Index0, SourceId),
        validate_and_load_source_text(Profile, Module, SourceText, SourceId),
        Option = load_text(SourceText),
        Index is Index0 + 1
    ;   reject_forbidden_spawn_option(Profile, Option0),
        Option = Option0,
        Index = Index0
    ),
    prepare_source_options(Profile, Module, GoalModule, Options0, Options, Index).

materialize_source_option(_, load_uri(URI), load_uri, SourceText) :-
    !,
    current_max_load_text_bytes(Limit),
    uri_to_source_limited(URI, Limit, SourceText).
materialize_source_option(GoalModule, Option0, Field, SourceText) :-
    source_option_field(Option0, Field),
    load_option_text(GoalModule, Option0, SourceText).

source_option_field(load_text(_), load_text).
source_option_field(load_list(_), load_list).
source_option_field(load_predicates(_), load_predicates).


validate_and_load_source_text(_Profile, _Module, SourceText0, _SourceId) :-
    text_to_string(SourceText0, SourceText),
    SourceText == "",
    !.
validate_and_load_source_text(Profile, Module, SourceText0, SourceId) :-
    text_to_string(SourceText0, SourceText),
    precheck_source_text(Profile, Module, SourceText),
    load_source_text_checked(SourceText, Module, SourceId).

load_source_text_checked(SourceText, Module, SourceId) :-
    sandbox_mode(Mode),
    load_source_text_mode_options(Mode, ModeOptions),
    append([ stream(Stream),
             module(Module),
             silent(true)
           ],
           ModeOptions,
           LoadOptions),
    setup_call_cleanup(
        open_chars_stream(SourceText, Stream),
        load_files(Module:SourceId, LoadOptions),
        close(Stream)).

load_source_text_mode_options(whitelist, [sandboxed(true)]) :-
    !.
load_source_text_mode_options(_, []).


precheck_source_text(Profile, Module, SourceText) :-
    setup_call_cleanup(
        open_string(SourceText, Stream),
        precheck_source_terms(Profile, Module, Stream),
        close(Stream)
    ).

precheck_source_terms(Profile, Module, Stream) :-
    read_term(Stream, Term, [module(Module)]),
    (   Term == end_of_file
    ->  true
    ;   precheck_source_term(Profile, Module, Term),
        precheck_source_terms(Profile, Module, Stream)
    ).

precheck_source_term(Profile, _Module, (:- Directive)) :-
    !,
    reject_forbidden_directive(Profile, Directive).
precheck_source_term(Profile, Module, (Head :- Body)) :-
    !,
    reject_qualified_head(Head),
    reject_forbidden_goal(Profile, Module, Body).
precheck_source_term(Profile, Module, Rule) :-
    Rule = (_Head --> _Body),
    !,
    dcg_translate_rule(Rule, Expanded),
    precheck_expanded_source_term(Profile, Module, Expanded).
precheck_source_term(_Profile, _Module, Fact) :-
    reject_qualified_head(Fact).

precheck_expanded_source_term(_, _, []) :-
    !.
precheck_expanded_source_term(Profile, Module, [Term|Terms]) :-
    !,
    precheck_expanded_source_term(Profile, Module, Term),
    precheck_expanded_source_term(Profile, Module, Terms).
precheck_expanded_source_term(Profile, Module, Term) :-
    precheck_source_term(Profile, Module, Term).

reject_qualified_head(Head) :-
    (   Head = _:_ 
    ->  throw(error(permission_error(clause, sandboxed, Head),
                    context(node_sandbox:reject_qualified_head/1,
                            'module-qualified clause heads are not allowed in sandbox mode')))
    ;   callable(Head)
    ->  true
    ;   throw(error(type_error(callable, Head),
                    context(node_sandbox:reject_qualified_head/1,
                            'source term must be a fact or rule')))
    ).


reject_forbidden_spawn_option(_Profile, Option) :-
    nonvar(Option),
    Option = node(_),
    spawn_option_node_allowed(Option),
    !.
reject_forbidden_spawn_option(_Profile, Option) :-
    nonvar(Option),
    Option = node(_),
    !,
    throw(error(permission_error(option, sandboxed, Option),
                context(node_sandbox:reject_forbidden_spawn_option/2,
                        'spawn option is disabled in sandbox mode'))).
reject_forbidden_spawn_option(_, _).

spawn_option_node_allowed(node(NodeURL0)) :-
    spawn_option_node_origin_allowed(NodeURL0),
    !.

spawn_option_node_origin_allowed(NodeURL0) :-
    text_to_string(NodeURL0, NodeURL),
    uri_components(NodeURL, Components),
    uri_data(scheme, Components, Scheme0),
    nonvar(Scheme0),
    downcase_atom(Scheme0, Scheme),
    memberchk(Scheme, [http, https]),
    uri_data(authority, Components, Authority),
    nonvar(Authority),
    uri_authority_components(Authority, AuthorityComponents),
    uri_authority_data(host, AuthorityComponents, Host0),
    nonvar(Host0),
    downcase_atom(Host0, Host),
    memberchk(Host, [localhost, '127.0.0.1', '::1', '[::1]']).
spawn_option_node_origin_allowed(NodeURL0) :-
    current_node_value(load_uri_allowed_origins, Origins0),
    Origins0 \== unrestricted,
    catch(normalize_load_uri_allowed_origins(Origins0, AllowedOrigins), _, fail),
    catch(normalize_load_uri_allowed_origins([NodeURL0], [Origin]), _, fail),
    memberchk(Origin, AllowedOrigins).


reject_forbidden_directive(_Profile, Directive) :-
    sandbox_mode(Mode),
    sandbox_forbidden_directive(Mode, Directive, _Category),
    !,
    throw(error(permission_error(execute, sandboxed_directive, (:- Directive)),
                context(node_sandbox:reject_forbidden_directive/2,
                        'directive is disabled in sandbox mode'))).
reject_forbidden_directive(_, _).

sandbox_forbidden_directive(_, use_module(_), module_loading).
sandbox_forbidden_directive(_, use_module(_, _), module_loading).
sandbox_forbidden_directive(_, ensure_loaded(_), module_loading).
sandbox_forbidden_directive(_, load_files(_), module_loading).
sandbox_forbidden_directive(_, load_files(_, _), module_loading).
sandbox_forbidden_directive(_, include(_), module_loading).
sandbox_forbidden_directive(_, consult(_), module_loading).
sandbox_forbidden_directive(_, reconsult(_), module_loading).
sandbox_forbidden_directive(_, initialization(_), startup_effects).
sandbox_forbidden_directive(_, initialization(_, _), startup_effects).
sandbox_forbidden_directive(_, module(_), module_state).
sandbox_forbidden_directive(_, module(_, _), module_state).
sandbox_forbidden_directive(_, redefine_system_predicate(_), runtime_override).
sandbox_forbidden_directive(blacklist, op(_, _, _), parser_state).
sandbox_forbidden_directive(blacklist, char_conversion(_, _), parser_state).
sandbox_forbidden_directive(blacklist, set_prolog_flag(_, _), runtime_state).

reject_forbidden_goal(Profile, Module, Goal) :-
    sandbox_mode(Mode),
    walk_goal(sandbox_check(Mode, Profile, Module), Goal).

sandbox_check(Mode, Profile, Module, Goal) :-
    (   Goal = (QM:Inner),
        atom(QM)
    ->  % Qualified goal — dispatch on module, then on inner goal functor
        (   QM == actor,
            sandbox_check_actor_(Inner, Profile, Module)
        ->  true
        ;   QM == node
        ->  reject_forbidden_qualified_goal(Profile, QM, Inner),
            reject_forbidden_goal(Profile, QM, Inner)
        ;   Mode == blacklist,
            QM == Module
        ->  reject_forbidden_goal(Profile, QM, Inner)
        ;   Mode == blacklist
        ->  throw(error(permission_error(call, sandboxed, QM:Inner),
                        context(node_sandbox:reject_forbidden_goal/3,
                                'module-qualified goal is disabled in blacklist sandbox mode')))
        ;   reject_forbidden_qualified_goal(Profile, QM, Inner),
            reject_forbidden_goal(Profile, QM, Inner)
        )
    ;   % Unqualified goal — dispatch on goal functor
        (   sandbox_check_unqualified_(Mode, Goal, Profile, Module)
        ->  true
        ;   sandbox_forbidden_goal(Mode, Module, Goal, Category)
        ->  throw_forbidden_goal(Goal, Category)
        ;   true
        )
    ).

sandbox_enforce_goal(whitelist, Module, Goal) :-
    (   sandbox_public_goal(Goal)
    ->  true
    ;   sandbox:safe_goal(Module:Goal)
    ).
sandbox_enforce_goal(blacklist, _Module, _Goal).
sandbox_enforce_goal(off, _Module, _Goal).

%!  sandbox_check_actor_(+Goal, +Profile, +Module) is semidet.
%
%   Handle actor-qualified goals. Goal is first for first-argument
%   indexing. No catch-all — fails for unrecognized actor goals,
%   falling back to the generic qualified-goal handler.

sandbox_check_actor_(receive(Clauses), Profile, Module) :-
    reject_receive_clauses(Profile, Module, Clauses).
sandbox_check_actor_(receive(Clauses, Options), Profile, Module) :-
    reject_receive_clauses(Profile, Module, Clauses),
    reject_receive_options(Profile, Module, Options).
sandbox_check_actor_(spawn(Goal), Profile, Module) :-
    sandbox_check_goal_in_module(Profile, Module, Goal).
sandbox_check_actor_(spawn(Goal, _Pid), Profile, Module) :-
    sandbox_check_goal_in_module(Profile, Module, Goal).
sandbox_check_actor_(spawn(Goal, _Pid, Options), Profile, Module) :-
    reject_nested_spawn_goal(Profile, Module, Goal, Options).
sandbox_check_actor_(with_io_target(_Target, Goal), Profile, Module) :-
    reject_forbidden_goal(Profile, Module, Goal).

%!  sandbox_check_unqualified_(+Goal, +Profile, +Module) is semidet.
%
%   Handle unqualified goals. Goal is first for first-argument
%   indexing. No catch-all — fails for non-structural goals,
%   falling back to the forbidden_plain_goal check.

sandbox_check_unqualified_(blacklist, clause(Head, Body), _Profile, Module) :-
    allow_local_clause_goal(Module, Head, Body).
sandbox_check_unqualified_(blacklist, format(Sink, Format, _Args), _Profile, _Module) :-
    format_memory_sink(Sink),
    reject_format_call_specifier(Format).
sandbox_check_unqualified_(blacklist, assert(Clause), Profile, Module) :-
    precheck_dynamic_clause_term(Profile, Module, Clause).
sandbox_check_unqualified_(blacklist, assert(Clause, _Ref), Profile, Module) :-
    precheck_dynamic_clause_term(Profile, Module, Clause).
sandbox_check_unqualified_(blacklist, asserta(Clause), Profile, Module) :-
    precheck_dynamic_clause_term(Profile, Module, Clause).
sandbox_check_unqualified_(blacklist, asserta(Clause, _Ref), Profile, Module) :-
    precheck_dynamic_clause_term(Profile, Module, Clause).
sandbox_check_unqualified_(blacklist, assertz(Clause), Profile, Module) :-
    precheck_dynamic_clause_term(Profile, Module, Clause).
sandbox_check_unqualified_(blacklist, assertz(Clause, _Ref), Profile, Module) :-
    precheck_dynamic_clause_term(Profile, Module, Clause).
sandbox_check_unqualified_(blacklist, time(Goal), Profile, Module) :-
    allow_local_time_goal(Profile, Module, Goal).
sandbox_check_unqualified_(_, receive(Clauses), Profile, Module) :-
    reject_receive_clauses(Profile, Module, Clauses).
sandbox_check_unqualified_(_, receive(Clauses, Options), Profile, Module) :-
    reject_receive_clauses(Profile, Module, Clauses),
    reject_receive_options(Profile, Module, Options).
sandbox_check_unqualified_(_, spawn(Goal), Profile, Module) :-
    sandbox_check_goal_in_module(Profile, Module, Goal).
sandbox_check_unqualified_(_, spawn(Goal, _Pid), Profile, Module) :-
    sandbox_check_goal_in_module(Profile, Module, Goal).
sandbox_check_unqualified_(_, spawn(Goal, _Pid, Options), Profile, Module) :-
    reject_nested_spawn_goal(Profile, Module, Goal, Options).
sandbox_check_unqualified_(_, toplevel_call(_Pid, Goal), Profile, Module) :-
    reject_forbidden_goal(Profile, Module, Goal).
sandbox_check_unqualified_(_, toplevel_call(_Pid, Goal, Options), Profile, Module) :-
    reject_forbidden_goal(Profile, Module, Goal),
    reject_toplevel_call_options(Profile, Options).
sandbox_check_unqualified_(_, with_io_target(_Target, Goal), Profile, Module) :-
    reject_forbidden_goal(Profile, Module, Goal).

sandbox_public_goal(toplevel_spawn(_)).
sandbox_public_goal(toplevel_spawn(_, _)).
sandbox_public_goal(toplevel_call(_, _)).
sandbox_public_goal(toplevel_call(_, _, _)).
sandbox_public_goal(toplevel_next(_)).
sandbox_public_goal(toplevel_next(_, _)).
sandbox_public_goal(toplevel_stop(_)).
sandbox_public_goal(toplevel_halt(_, _)).
sandbox_public_goal(toplevel_abort(_)).

forbidden_plain_goal(consult(_)).
forbidden_plain_goal(reconsult(_)).
forbidden_plain_goal(ensure_loaded(_)).
forbidden_plain_goal(load_files(_)).
forbidden_plain_goal(load_files(_, _)).
forbidden_plain_goal(use_module(_)).
forbidden_plain_goal(use_module(_, _)).

sandbox_forbidden_goal(_Mode, _Module, Goal, module_loading) :-
    forbidden_plain_goal(Goal),
    !.
sandbox_forbidden_goal(blacklist, Module, Goal, Category) :-
    blacklisted_goal_in_context(Module, Goal, Category),
    !.

throw_forbidden_goal(Goal, Category) :-
    throw(error(permission_error(call, sandboxed, Goal),
                context(node_sandbox:reject_forbidden_goal/3,
                        Category))).

blacklisted_goal_in_context(Module, Goal, Category) :-
    blacklisted_goal_pattern(Goal, Category),
    \+ goal_shadowed_by_local_predicate(Module, Goal).

goal_shadowed_by_local_predicate(Module, Goal) :-
    atom(Module),
    callable(Goal),
    functor(Goal, Name, Arity),
    current_predicate(Module:Name/Arity),
    functor(Head, Name, Arity),
    \+ predicate_property(Module:Head, imported_from(_)).

blacklisted_goal_pattern(open(_, _, _), iso_stream_io).
blacklisted_goal_pattern(open(_, _, _, _), iso_stream_io).
blacklisted_goal_pattern(close(_), iso_stream_io).
blacklisted_goal_pattern(close(_, _), iso_stream_io).
blacklisted_goal_pattern(current_input(_), iso_stream_io).
blacklisted_goal_pattern(current_output(_), iso_stream_io).
blacklisted_goal_pattern(set_input(_), iso_stream_io).
blacklisted_goal_pattern(set_output(_), iso_stream_io).
blacklisted_goal_pattern(at_end_of_stream, iso_stream_io).
blacklisted_goal_pattern(at_end_of_stream(_), iso_stream_io).
blacklisted_goal_pattern(stream_property(_, _), iso_stream_io).
blacklisted_goal_pattern(set_stream_position(_, _), iso_stream_io).
blacklisted_goal_pattern(flush_output, iso_stream_io).
blacklisted_goal_pattern(flush_output(_), iso_stream_io).
blacklisted_goal_pattern(get_byte(_), iso_stream_io).
blacklisted_goal_pattern(get_byte(_, _), iso_stream_io).
blacklisted_goal_pattern(get_char(_), iso_stream_io).
blacklisted_goal_pattern(get_char(_, _), iso_stream_io).
blacklisted_goal_pattern(get_code(_), iso_stream_io).
blacklisted_goal_pattern(get_code(_, _), iso_stream_io).
blacklisted_goal_pattern(peek_byte(_), iso_stream_io).
blacklisted_goal_pattern(peek_byte(_, _), iso_stream_io).
blacklisted_goal_pattern(peek_char(_), iso_stream_io).
blacklisted_goal_pattern(peek_char(_, _), iso_stream_io).
blacklisted_goal_pattern(peek_code(_), iso_stream_io).
blacklisted_goal_pattern(peek_code(_, _), iso_stream_io).
blacklisted_goal_pattern(put_byte(_), iso_stream_io).
blacklisted_goal_pattern(put_byte(_, _), iso_stream_io).
blacklisted_goal_pattern(put_char(_), iso_stream_io).
blacklisted_goal_pattern(put_char(_, _), iso_stream_io).
blacklisted_goal_pattern(put_code(_), iso_stream_io).
blacklisted_goal_pattern(put_code(_, _), iso_stream_io).
blacklisted_goal_pattern(read(_), iso_stream_io).
blacklisted_goal_pattern(read(_, _), iso_stream_io).
blacklisted_goal_pattern(read_term(_, _), iso_stream_io).
blacklisted_goal_pattern(read_term(_, _, _), iso_stream_io).
blacklisted_goal_pattern(write(_), iso_stream_io).
blacklisted_goal_pattern(write(_, _), iso_stream_io).
blacklisted_goal_pattern(nl(_), iso_stream_io).
blacklisted_goal_pattern(writeln(_, _), iso_stream_io).
blacklisted_goal_pattern(print(_, _), iso_stream_io).
blacklisted_goal_pattern(writeq(_), iso_stream_io).
blacklisted_goal_pattern(writeq(_, _), iso_stream_io).
blacklisted_goal_pattern(write_canonical(_), iso_stream_io).
blacklisted_goal_pattern(write_canonical(_, _), iso_stream_io).
blacklisted_goal_pattern(write_term(_, _), iso_stream_io).
blacklisted_goal_pattern(write_term(_, _, _), iso_stream_io).
blacklisted_goal_pattern(format(_, _, _), iso_stream_io).
blacklisted_goal_pattern(time(_), runtime_timing).
blacklisted_goal_pattern(current_predicate(_), runtime_reflection).
blacklisted_goal_pattern(predicate_property(_, _), runtime_reflection).
blacklisted_goal_pattern(current_prolog_flag(_, _), runtime_reflection).
blacklisted_goal_pattern(current_op(_, _, _), runtime_reflection).
blacklisted_goal_pattern(current_char_conversion(_, _), runtime_reflection).
blacklisted_goal_pattern(set_prolog_flag(_, _), runtime_state).
blacklisted_goal_pattern(char_conversion(_, _), parser_state).
blacklisted_goal_pattern(op(_, _, _), parser_state).
blacklisted_goal_pattern(halt, runtime_state).
blacklisted_goal_pattern(halt(_), runtime_state).
blacklisted_goal_pattern(nb_setval(_, _), stateful_term_storage).
blacklisted_goal_pattern(b_setval(_, _), stateful_term_storage).
blacklisted_goal_pattern(nb_getval(_, _), stateful_term_storage).
blacklisted_goal_pattern(b_getval(_, _), stateful_term_storage).
blacklisted_goal_pattern(shell, shell_commands).
blacklisted_goal_pattern(shell(_), shell_commands).
blacklisted_goal_pattern(shell(_, _), shell_commands).
blacklisted_goal_pattern(cd, shell_commands).
blacklisted_goal_pattern(cd(_), shell_commands).
blacklisted_goal_pattern(pushd, shell_commands).
blacklisted_goal_pattern(pushd(_), shell_commands).
blacklisted_goal_pattern(popd, shell_commands).
blacklisted_goal_pattern(dirs, shell_commands).
blacklisted_goal_pattern(pwd, shell_commands).
blacklisted_goal_pattern(ls, shell_commands).
blacklisted_goal_pattern(ls(_), shell_commands).
blacklisted_goal_pattern(mv(_, _), shell_commands).
blacklisted_goal_pattern(rm(_), shell_commands).
blacklisted_goal_pattern(file_style(_, _), shell_commands).
blacklisted_goal_pattern(message_queue_create(_, _), iso_threads).
blacklisted_goal_pattern(message_queue_destroy(_), iso_threads).
blacklisted_goal_pattern(message_queue_property(_, _), iso_threads).
blacklisted_goal_pattern(mutex_create(_, _), iso_threads).
blacklisted_goal_pattern(mutex_destroy(_), iso_threads).
blacklisted_goal_pattern(mutex_lock(_), iso_threads).
blacklisted_goal_pattern(mutex_property(_, _), iso_threads).
blacklisted_goal_pattern(mutex_trylock(_), iso_threads).
blacklisted_goal_pattern(mutex_unlock(_), iso_threads).
blacklisted_goal_pattern(thread_create(_, _, _), iso_threads).
blacklisted_goal_pattern(thread_detach(_), iso_threads).
blacklisted_goal_pattern(thread_get_message(_), iso_threads).
blacklisted_goal_pattern(thread_get_message(_, _), iso_threads).
blacklisted_goal_pattern(thread_get_message(_, _, _), iso_threads).
blacklisted_goal_pattern(thread_peek_message(_), iso_threads).
blacklisted_goal_pattern(thread_peek_message(_, _), iso_threads).
blacklisted_goal_pattern(thread_property(_, _), iso_threads).
blacklisted_goal_pattern(thread_self(_), iso_threads).
blacklisted_goal_pattern(thread_send_message(_, _), iso_threads).
blacklisted_goal_pattern(thread_signal(_, _), iso_threads).
blacklisted_goal_pattern(with_mutex(_, _), iso_threads).

precheck_dynamic_clause_term(Profile, Module, Clause) :-
    precheck_source_term(Profile, Module, Clause).

allow_local_time_goal(Profile, Module, Goal) :-
    (   goal_shadowed_by_local_predicate(Module, time(Goal))
    ->  reject_forbidden_goal(Profile, Module, Goal)
    ;   throw_forbidden_goal(time(Goal), runtime_timing)
    ).

format_memory_sink(atom(_)).
format_memory_sink(string(_)).
format_memory_sink(codes(_)).
format_memory_sink(chars(_)).

%!  reject_format_call_specifier(+Format) is det.
%
%   Throws a permission error if Format contains the ~@ specifier,
%   which calls arbitrary goals from the argument list, bypassing
%   the sandbox.

reject_format_call_specifier(Format) :-
    format_to_atom_safe(Format, Atom),
    (   sub_atom(Atom, _, 2, _, '~@')
    ->  throw(error(permission_error(use, format_specifier, '~@'),
                    context(format/2,
                            'the ~@ format specifier is disabled for security')))
    ;   true
    ).

%!  format_to_atom_safe(+Format, -Atom) is det.
%
%   Normalises a format argument (atom, string, or code list) to an
%   atom so that sub_atom/5 can scan it for dangerous specifiers.
%   Returns '' for unrecognised types so the check is conservatively
%   passed (the underlying format/3 will error on bad types anyway).

format_to_atom_safe(Format, Atom) :-
    (   atom(Format)
    ->  Atom = Format
    ;   string(Format)
    ->  atom_string(Atom, Format)
    ;   is_list(Format)
    ->  catch(atom_codes(Atom, Format), _, Atom = '')
    ;   Atom = ''
    ).

allow_local_clause_goal(_Module, Head0, Body) :-
    (   nonvar(Head0),
        Head0 = _:_
    ->  throw(error(permission_error(call, sandboxed, clause(Head0, Body)),
                    context(node_sandbox:reject_forbidden_goal/3,
                            'module-qualified clause/2 heads are disabled in blacklist sandbox mode')))
    ;   true
    ).

reject_forbidden_qualified_goal(Profile, node, Goal) :-
    builtin_goal_policy(Goal, Family, _RequiredProfile),
    !,
    (   builtin_family_enabled(Profile, Family)
    ->  true
    ;   throw(error(permission_error(call, sandboxed, node:Goal),
                    context(node_sandbox:reject_forbidden_goal/2,
                            'predicate not available in the current profile')))
    ).
reject_forbidden_qualified_goal(_, _, _).

reject_spawn_goal_options(Profile, Options) :-
    is_list(Options),
    !,
    forall(member(Option, Options),
           reject_spawn_goal_option(Profile, Option)).
reject_spawn_goal_options(_, _).

reject_nested_spawn_goal(Profile, GoalModule, Goal, Options) :-
    (   has_deferred_nested_source_option(Options)
    ->  reject_deferred_nested_spawn_options(Profile, Options),
        sandbox_check_goal_in_module(Profile, GoalModule, Goal)
    ;   has_source_like_option(Options)
    ->  sandbox_check_goal_with_options(Profile, GoalModule, Goal, Options)
    ;   sandbox_check_spawn_options(Profile, Options),
        sandbox_check_goal_in_module(Profile, GoalModule, Goal)
    ).

has_source_like_option(Options) :-
    is_list(Options),
    member(Option, Options),
    source_option_like(Option),
    !.

has_deferred_nested_source_option(Options) :-
    is_list(Options),
    member(Option, Options),
    deferred_nested_source_option(Option),
    !.

%!  deferred_nested_source_option(+Option) is semidet.
%
%   True when a nested spawn option must not be materialized during
%   static source pre-checking.  load_predicates/1 is always deferred
%   because the predicates it references may be defined in the same
%   source text being loaded (chicken-and-egg).  Other source-like
%   options are deferred only when they are non-ground (contain
%   variables), since their content is not yet known.  Runtime spawn
%   validates load_predicates source through sandbox_prepare_public_spawn.
deferred_nested_source_option(load_predicates(_)) :- !.
deferred_nested_source_option(Option) :-
    source_option_like(Option),
    \+ ground(Option).

reject_deferred_nested_spawn_options(Profile, Options) :-
    forall(
        member(Option, Options),
        reject_deferred_nested_spawn_option(Profile, Option)
    ).

reject_deferred_nested_spawn_option(_Profile, Option) :-
    source_option_like(Option),
    !.
reject_deferred_nested_spawn_option(Profile, Option) :-
    reject_forbidden_spawn_option(Profile, Option).

reject_spawn_goal_option(Profile, Option) :-
    source_option_like(Option),
    !,
    sandbox_check_source_options(Profile, actor, [Option]).
reject_spawn_goal_option(Profile, Option) :-
    reject_forbidden_spawn_option(Profile, Option).

source_option_like(load_text(_)).
source_option_like(load_list(_)).
source_option_like(load_predicates(_)).
source_option_like(load_uri(_)).

reject_toplevel_call_options(Profile, Options) :-
    is_list(Options),
    !,
    forall(member(Option, Options),
           reject_toplevel_call_option(Profile, Option)).
reject_toplevel_call_options(_, _).

reject_toplevel_call_option(Profile, load_text(SourceText)) :-
    !,
    sandbox_check_source_text(Profile, actor, SourceText).
reject_toplevel_call_option(Profile, load_list(Terms)) :-
    !,
    sandbox_check_source_options(Profile, actor, [load_list(Terms)]).
reject_toplevel_call_option(Profile, load_uri(URI)) :-
    !,
    sandbox_check_source_options(Profile, actor, [load_uri(URI)]).
reject_toplevel_call_option(Profile, load_predicates(PIs)) :-
    !,
    sandbox_check_source_options(Profile, actor, [load_predicates(PIs)]).
reject_toplevel_call_option(_, _).

reject_toplevel_next_options(Profile, Options) :-
    is_list(Options),
    !,
    forall(member(Option, Options),
           reject_toplevel_next_option(Profile, Option)).
reject_toplevel_next_options(_, _).

reject_toplevel_next_option(Profile, load_text(SourceText)) :-
    !,
    sandbox_check_source_text(Profile, actor, SourceText).
reject_toplevel_next_option(Profile, load_list(Terms)) :-
    !,
    sandbox_check_source_options(Profile, actor, [load_list(Terms)]).
reject_toplevel_next_option(Profile, load_uri(URI)) :-
    !,
    sandbox_check_source_options(Profile, actor, [load_uri(URI)]).
reject_toplevel_next_option(Profile, load_predicates(PIs)) :-
    !,
    sandbox_check_source_options(Profile, actor, [load_predicates(PIs)]).
reject_toplevel_next_option(_, _).

reject_receive_options(Profile, Module, Options) :-
    is_list(Options),
    !,
    forall(member(Option, Options),
           reject_receive_option(Profile, Module, Option)).
reject_receive_options(_, _, _).

reject_receive_option(Profile, Module, on_timeout(Goal)) :-
    !,
    reject_forbidden_goal(Profile, Module, Goal).
reject_receive_option(_, _, _).

reject_receive_clauses(Profile, _CurrentModule, Module:{Clauses}) :-
    atom(Module),
    !,
    reject_receive_clauses(Profile, Module, Clauses).
reject_receive_clauses(Profile, Module, Clauses) :-
    reject_receive_clauses_1(Profile, Module, Clauses).

reject_receive_clauses_1(Profile, Module, (Clause ; Clauses)) :-
    !,
    reject_receive_clauses_1(Profile, Module, Clause),
    reject_receive_clauses_1(Profile, Module, Clauses).
reject_receive_clauses_1(Profile, Module, (Head -> Body)) :-
    !,
    reject_receive_head(Profile, Module, Head),
    reject_forbidden_goal(Profile, Module, Body).
reject_receive_clauses_1(_, _, _).

reject_receive_head(Profile, Module, if(_Pattern, Guard)) :-
    !,
    reject_forbidden_goal(Profile, Module, Guard).
reject_receive_head(_, _, _).


receive_meta_calls(Clauses, Options, Calls) :-
    receive_clause_calls(Clauses, ClauseCalls),
    receive_option_calls(Options, OptionCalls),
    append(ClauseCalls, OptionCalls, Calls).

receive_clause_calls(Module:{Clauses}, Calls) :-
    atom(Module),
    !,
    receive_clause_calls(Clauses, Calls).
receive_clause_calls((Clause ; Clauses), Calls) :-
    !,
    receive_clause_calls(Clause, Calls0),
    receive_clause_calls(Clauses, Calls1),
    append(Calls0, Calls1, Calls).
receive_clause_calls((Head -> Body), Calls) :-
    !,
    receive_head_calls(Head, GuardCalls),
    append(GuardCalls, [Body], Calls).
receive_clause_calls(_, []).

receive_head_calls(if(_Pattern, Guard), [Guard]) :-
    !.
receive_head_calls(_, []).

receive_option_calls(Options, Calls) :-
    is_list(Options),
    !,
    findall(Goal,
            member(on_timeout(Goal), Options),
            Calls).
receive_option_calls(_, []).


sandbox:safe_primitive(actor:self(_)).
sandbox:safe_primitive(actor:monitor(_, _)).
sandbox:safe_primitive(actor:demonitor(_)).
sandbox:safe_primitive(actor:demonitor(_, _)).
sandbox:safe_primitive(actor:register(_, _)).
sandbox:safe_primitive(actor:unregister(_)).
sandbox:safe_primitive(actor:whereis(_, _)).
sandbox:safe_primitive(actor:exit(_)).
sandbox:safe_primitive(actor:exit(_, _)).
sandbox:safe_primitive(actor:send(_, _)).
sandbox:safe_primitive(actor:send(_, _, _)).
sandbox:safe_primitive(actor:!(_, _)).
sandbox:safe_primitive(actor:cancel(_)).
sandbox:safe_primitive(actor:output(_)).
sandbox:safe_primitive(actor:output(_, _)).
sandbox:safe_primitive(actor:terminal_output(_)).
sandbox:safe_primitive(actor:terminal_output(_, _)).
sandbox:safe_primitive(actor:input(_, _)).
sandbox:safe_primitive(actor:input(_, _, _)).
sandbox:safe_primitive(actor:respond(_, _)).
sandbox:safe_primitive(actor:flush).
sandbox:safe_primitive(actor:listing_private).
sandbox:safe_primitive(actor:listing_private(_)).

sandbox:safe_meta(call_cleanup(Goal, Cleanup), [Goal, Cleanup]).
sandbox:safe_meta(setup_call_cleanup(Setup, Goal, Cleanup), [Setup, Goal, Cleanup]).

sandbox:safe_meta(actor:receive(Clauses), Calls) :-
    receive_meta_calls(Clauses, [], Calls).
sandbox:safe_meta(actor:receive(Clauses, Options), Calls) :-
    receive_meta_calls(Clauses, Options, Calls).
sandbox:safe_meta(actor:spawn(_Goal), []).
sandbox:safe_meta(actor:spawn(_Goal, _Pid), []).
sandbox:safe_meta(actor:spawn(_Goal, _Pid, _Options), []).
sandbox:safe_meta(actor:with_io_target(_Target, Goal), [Goal]).
