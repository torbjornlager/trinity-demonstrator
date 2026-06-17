:- module(node_interaction_log, [
    log_interaction_request/2,
    log_browser_interaction_request/2,
    current_interaction_log_file/1
]).

/** <module> Durable Demonstrator Interaction Log

Append-only JSONL logging for public demonstrator usage analytics.
This is intentionally separate from node_log.pl, which keeps a bounded
in-memory activity log for the admin UI.
*/

:- use_module(library(apply)).
:- use_module(library(filesex)).
:- use_module(library(http/json)).
:- use_module(library(settings)).

:- use_module(node_auth, [request_principal/2]).
:- use_module(node_log, [request_client_meta/3]).
:- use_module(node_runtime_state, [current_node_value/2]).
:- use_module(node_owner_tag, [request_owner_tagged/1, request_agent_tagged/1]).

:- setting(interaction_log_file, atom, 'logs/interactions.jsonl',
           'Append-only JSONL file for public demonstrator interaction events').
:- setting(max_interaction_log_bytes, integer, 0,
           'Rotate the interaction log when it reaches this size in bytes (0 = no rotation)').
:- setting(max_interaction_log_backups, integer, 5,
           'Number of rotated interaction-log backups to keep').


%!  log_interaction_request(+Request, +Event) is det.
%
%   Append a server-observed interaction event. Event must be a dict with an
%   `event` field.
log_interaction_request(Request, Event0) :-
    request_principal(Request, Principal),
    request_client_meta(Request, Principal, ClientMeta0),
    interaction_client_meta(ClientMeta0, ClientMeta1),
    add_owner_tag(Request, ClientMeta1, ClientMeta2),
    add_agent_tag(Request, ClientMeta2, ClientMeta),
    append_interaction_event(ClientMeta, Event0).


add_owner_tag(Request, Meta0, Meta) :-
    (   catch(request_owner_tagged(Request), _, fail)
    ->  put_dict(owner, Meta0, true, Meta)
    ;   Meta = Meta0
    ).


add_agent_tag(Request, Meta0, Meta) :-
    (   catch(request_agent_tagged(Request), _, fail)
    ->  put_dict(agent, Meta0, "claude", Meta)
    ;   Meta = Meta0
    ).


%!  log_browser_interaction_request(+Request, +Event) is det.
%
%   Append a browser-reported interaction event after allowlist validation.
log_browser_interaction_request(Request, Event0) :-
    browser_interaction_event(Event0, Event),
    log_interaction_request(Request, Event).


%!  current_interaction_log_file(-File) is det.
current_interaction_log_file(File) :-
    (   current_node_value(interaction_log_file, File0)
    ->  true
    ;   getenv('WEB_PROLOG_INTERACTION_LOG', File0)
    ->  true
    ;   setting(interaction_log_file, File0)
    ),
    absolute_file_name(File0, File, [access(none), file_errors(fail)]),
    !.
current_interaction_log_file(File) :-
    setting(interaction_log_file, File0),
    absolute_file_name(File0, File, [access(none)]).


append_interaction_event(ClientMeta, Event0) :-
    must_be(dict, Event0),
    get_dict(event, Event0, EventName0),
    text_value(EventName0, EventName),
    EventName \== "",
    event_clock(Now, At),
    sanitize_event_fields(Event0, Event1),
    strip_reserved_event_fields(Event1, Source, EventFields),
    dict_pairs(ClientMeta, _, MetaPairs),
    dict_pairs(EventFields, _, EventPairs),
    unique_key_pairs(
        [ at-At,
          ts-Now,
          event-EventName,
          source-Source
        | MetaPairs
        ],
        BasePairs
    ),
    append(BasePairs, EventPairs, Pairs0),
    unique_key_pairs(Pairs0, Pairs),
    dict_create(Event, _, Pairs),
    write_jsonl_event(Event).


write_jsonl_event(Event) :-
    current_interaction_log_file(File),
    file_directory_name(File, Dir),
    make_directory_path(Dir),
    with_mutex(
        node_interaction_log,
        (
            rotate_log_if_needed(File),
            setup_call_cleanup(
                open(File, append, Stream, [encoding(utf8)]),
                (
                    json_write_dict(Stream, Event, [width(0)]),
                    nl(Stream)
                ),
                close(Stream)
            )
        )
    ).


%!  rotate_log_if_needed(+File) is det.
%
%   Size-based rotation: when the log reaches max_interaction_log_bytes,
%   shift the backups (File.1 .. File.N) up and rename the live file to
%   File.1, so the next append starts fresh.  Called inside the
%   node_interaction_log mutex (single-writer, no race with appends).
%   Off by default (no max ⇒ unbounded, the demonstrator's behaviour);
%   the deploy bundle sets a bound.
rotate_log_if_needed(File) :-
    interaction_log_max_bytes(Max),
    Max > 0,
    exists_file(File),
    size_file(File, Size),
    Size >= Max,
    !,
    interaction_log_backups(Backups),
    rotate_backups(File, Backups).
rotate_log_if_needed(_).

rotate_backups(File, N) :-
    N >= 1,
    !,
    backup_name(File, N, Oldest),
    ( exists_file(Oldest) -> catch(delete_file(Oldest), _, true) ; true ),
    Upto is N - 1,
    (   Upto >= 1
    ->  numlist(1, Upto, Ascending),
        reverse(Ascending, Descending),
        forall(member(I, Descending), shift_backup(File, I))
    ;   true
    ),
    backup_name(File, 1, First),
    catch(rename_file(File, First), _, true).
rotate_backups(File, _) :-
    %  Zero backups configured: discard the rolled file.
    catch(delete_file(File), _, true).

shift_backup(File, I) :-
    backup_name(File, I, From),
    I1 is I + 1,
    backup_name(File, I1, To),
    ( exists_file(From) -> catch(rename_file(From, To), _, true) ; true ).

backup_name(File, I, Name) :-
    format(atom(Name), '~w.~w', [File, I]).

%!  interaction_log_max_bytes(-Max) is det.
%
%   Rotation threshold in bytes; a non-positive or unset value (incl.
%   the `unlimited` ceiling atom) means no rotation.
interaction_log_max_bytes(Max) :-
    (   catch(current_node_value(max_interaction_log_bytes, M), _, fail),
        integer(M)
    ->  Max = M
    ;   setting(max_interaction_log_bytes, Max0),
        integer(Max0)
    ->  Max = Max0
    ;   Max = 0
    ).

%!  interaction_log_backups(-N) is det.
%
%   Per-port runtime value when available (a request context), else the
%   global setting (the log is also written outside a port context,
%   e.g. portal_load), else the default.
interaction_log_backups(N) :-
    (   catch(current_node_value(max_interaction_log_backups, B), _, fail),
        integer(B),
        B >= 0
    ->  N = B
    ;   setting(max_interaction_log_backups, B0),
        integer(B0),
        B0 >= 0
    ->  N = B0
    ;   N = 5
    ).


browser_interaction_event(Event0, Event) :-
    must_be(dict, Event0),
    get_dict(event, Event0, EventName0),
    text_value(EventName0, EventName),
    allowed_browser_event(EventName),
    include_allowed_browser_field(Event0, EventName, Pairs),
    dict_create(Event, _, [event-EventName, source-"browser"|Pairs]).


allowed_browser_event("tutorial_call").
allowed_browser_event("example_spawn").
allowed_browser_event("portal_view").


include_allowed_browser_field(Event, EventName, Pairs) :-
    allowed_browser_fields(EventName, Fields),
    findall(
        Key-Value,
        (
            member(Key, Fields),
            get_dict(Key, Event, Value0),
            browser_field_value(Key, Value0, Value)
        ),
        Pairs
    ).


allowed_browser_fields("tutorial_call", [example, example_label, device]).
allowed_browser_fields("example_spawn",
                       [example, example_url, source_kind, transport, origin, device]).
allowed_browser_fields("portal_view", [device, route]).


browser_field_value(Key, Value0, Value) :-
    once(max_field_length(Key, MaxLength)),
    text_value(Value0, Text0),
    truncate_text(Text0, MaxLength, Value).


max_field_length(example, 160).
max_field_length(example_label, 240).
max_field_length(example_url, 300).
max_field_length(source_kind, 40).
max_field_length(transport, 40).
max_field_length(origin, 40).
max_field_length(device, 24).
max_field_length(route, 40).
max_field_length(_, 200).


sanitize_event_fields(Event0, Event) :-
    dict_pairs(Event0, _, Pairs0),
    maplist(sanitize_event_pair, Pairs0, Pairs),
    dict_create(Event, _, Pairs).


sanitize_event_pair(Key-Value0, Key-Value) :-
    (   number(Value0)
    ->  Value = Value0
    ;   text_value(Value0, Text0),
        truncate_text(Text0, 500, Value)
    ).


strip_reserved_event_fields(Event0, Source, Event) :-
    (   del_dict(source, Event0, Source0, Event1)
    ->  true
    ;   Source0 = "server",
        Event1 = Event0
    ),
    text_value(Source0, Source),
    (   del_dict(event, Event1, _, Event)
    ->  true
    ;   Event = Event1
    ).


unique_key_pairs(Pairs0, Pairs) :-
    reverse(Pairs0, Reversed),
    unique_key_pairs_1(Reversed, [], [], UniqueReversed),
    reverse(UniqueReversed, Pairs).


unique_key_pairs_1([], _, Pairs, Pairs).
unique_key_pairs_1([Key-_|Rest], Seen, Acc, Pairs) :-
    memberchk(Key, Seen),
    !,
    unique_key_pairs_1(Rest, Seen, Acc, Pairs).
unique_key_pairs_1([Key-Value|Rest], Seen, Acc, Pairs) :-
    unique_key_pairs_1(Rest, [Key|Seen], [Key-Value|Acc], Pairs).


text_value(Value0, Value) :-
    (   string(Value0)
    ->  Value = Value0
    ;   atom(Value0)
    ->  atom_string(Value0, Value)
    ;   number(Value0)
    ->  term_string(Value0, Value)
    ;   term_string(Value0, Value)
    ).


truncate_text(Text, MaxLength, Out) :-
    string_length(Text, Length),
    (   Length =< MaxLength
    ->  Out = Text
    ;   sub_string(Text, 0, MaxLength, _, Out)
    ).


event_clock(Now, At) :-
    get_time(Now),
    format_time(string(At), '%FT%TZ', Now).


interaction_client_meta(ClientMeta0, ClientMeta) :-
    (   get_dict(user_agent, ClientMeta0, UA0), UA0 \== ""
    ->  truncate_text(UA0, 240, UA),
        put_dict(user_agent, ClientMeta0, UA, ClientMeta1)
    ;   ClientMeta1 = ClientMeta0
    ),
    (   get_dict(principal, ClientMeta1, "anonymous"),
        get_dict(peer, ClientMeta1, Peer),
        Peer \== ""
    ->  format(string(ClientId), 'peer:~w', [Peer]),
        put_dict(client_id, ClientMeta1, ClientId, ClientMeta)
    ;   ClientMeta = ClientMeta1
    ).
