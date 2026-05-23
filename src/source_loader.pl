:- module(source_loader, [
    source_options/3,
    rewrite_source_options/3,
    load_sources/2,
    load_source_text/3,
    load_source_uri/3,
    source_id/3,
    load_option_text/3,
    load_options_text/3
]).

/** <module> Source Loading Helpers

Shared helpers for converting user-facing load options into normalized source
specifications and loading them into modules.
*/

:- use_module(node_client, [text_to_string/2]).
:- use_module(public_goal_guard, [
    blacklist_guard_active/0,
    rewrite_source_text_if_needed/3
]).
:- use_module(source_utils, [
    terms_to_source/2,
    predicates_to_source/3,
    uri_atom/2,
    open_source_uri/2,
    uri_to_source/2,
    append_source_text/3
]).


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
    rewrite_source_text_if_needed(Module, Source0, Source),
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
    (   blacklist_guard_active
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
