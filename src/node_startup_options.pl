:- module(node_startup_options, [
    node_options/24
]).

/** <module> Node Startup Option Parsing

Build shared-db source text and forward remaining options to `http_server/2`.
*/

:- use_module(library(apply)).
:- use_module(library(filesex), [directory_file_path/3]).
:- use_module(node_client, [text_to_string/2]).
:- use_module(source_utils, [
    uri_atom/2,
    uri_to_source/2,
    append_source_text/3
]).


%!  node_options(+Options, -SharedDB, -SandboxMode, -Profile, -AuthMode,
%!               -DevPrincipal, -DevCapabilities, -PrincipalPolicies,
%!               -Timeout, -CacheSize, -MaxInflightCalls,
%!               -MaxSessionsPerPrincipal, -MaxWSActorsPerPrincipal,
%!               -MaxTermTextBytes, -MaxLoadTextBytes, -MaxWSFrameBytes,
%!               -MaxAdminJSONBytes, -RateWindowSeconds,
%!               -MaxCallRequestsPerWindow,
%!               -MaxSessionSpawnsPerWindow, -MaxWSCommandsPerWindow,
%!               -LoadURIAllowedOrigins, -RelationPatterns, -HTTPOptions) is det.
%
%   Split node options into shared-db source options and passthrough
%   `http_server/2` options. `relations([...])` collects RELATION profile
%   query patterns separately from HTTP server options.
node_options(Options, SharedDB, SandboxMode, Profile, AuthMode,
             DevPrincipal, DevCapabilities, PrincipalPolicies, Timeout,
             CacheSize, MaxInflightCalls, MaxSessionsPerPrincipal,
             MaxWSActorsPerPrincipal, MaxTermTextBytes, MaxLoadTextBytes,
             MaxWSFrameBytes, MaxAdminJSONBytes, RateWindowSeconds,
             MaxCallRequestsPerWindow, MaxSessionSpawnsPerWindow,
             MaxWSCommandsPerWindow, LoadURIAllowedOrigins, RelationPatterns,
             HTTPOptions) :-
    default_node_option_state(State0),
    foldl(collect_node_option, Options, State0, State),
    node_options_from_state(State, SharedDB, SandboxMode, Profile, AuthMode,
                            DevPrincipal, DevCapabilities, PrincipalPolicies,
                            Timeout, CacheSize, MaxInflightCalls,
                            MaxSessionsPerPrincipal, MaxWSActorsPerPrincipal,
                            MaxTermTextBytes, MaxLoadTextBytes,
                            MaxWSFrameBytes, MaxAdminJSONBytes,
                            RateWindowSeconds, MaxCallRequestsPerWindow,
                            MaxSessionSpawnsPerWindow,
                            MaxWSCommandsPerWindow, LoadURIAllowedOrigins,
                            RelationPatterns, HTTPOptions).


default_node_option_state(state{
    has_shared:false,
    shared_db:"",
    sandbox:blacklist,
    profile:actor,
    auth:open,
    dev_principal:dev,
    %  Safe-by-default: dev capabilities used to be [admin], which
    %  silently gave full admin to every loopback request on
    %  auth(dev) nodes.  [execute] matches the open-mode default
    %  surface; admin must be opted into explicitly via
    %  dev_capabilities([admin]).  See node_auth.pl's
    %  request_dev_principal/2 docstring for the deployment caveat.
    dev_capabilities:[execute],
    principal_policies_rev:[],
    timeout:default,
    cache_size:default,
    max_inflight_calls:default,
    max_sessions_per_principal:default,
    max_ws_actors_per_principal:default,
    max_term_text_bytes:default,
    max_load_text_bytes:default,
    max_ws_frame_bytes:default,
    max_admin_json_bytes:default,
    rate_window_seconds:default,
    max_call_requests_per_window:default,
    max_session_spawns_per_window:default,
    max_ws_commands_per_window:default,
    load_uri_allowed_origins:default,
    relation_patterns:[],
    http_options_rev:[]
}).


node_options_from_state(State, SharedDB, SandboxMode, Profile, AuthMode,
                        DevPrincipal, DevCapabilities, PrincipalPolicies,
                        Timeout, CacheSize, MaxInflightCalls,
                        MaxSessionsPerPrincipal, MaxWSActorsPerPrincipal,
                        MaxTermTextBytes, MaxLoadTextBytes, MaxWSFrameBytes,
                        MaxAdminJSONBytes, RateWindowSeconds,
                        MaxCallRequestsPerWindow, MaxSessionSpawnsPerWindow,
                        MaxWSCommandsPerWindow, LoadURIAllowedOrigins,
                        RelationPatterns, HTTPOptions) :-
    (   State.has_shared == true
    ->  SharedDB = State.shared_db
    ;   default_node_shared_db(SharedDB)
    ),
    SandboxMode = State.sandbox,
    Profile = State.profile,
    AuthMode = State.auth,
    DevPrincipal = State.dev_principal,
    DevCapabilities = State.dev_capabilities,
    reverse(State.principal_policies_rev, PrincipalPolicies),
    Timeout = State.timeout,
    CacheSize = State.cache_size,
    MaxInflightCalls = State.max_inflight_calls,
    MaxSessionsPerPrincipal = State.max_sessions_per_principal,
    MaxWSActorsPerPrincipal = State.max_ws_actors_per_principal,
    MaxTermTextBytes = State.max_term_text_bytes,
    MaxLoadTextBytes = State.max_load_text_bytes,
    MaxWSFrameBytes = State.max_ws_frame_bytes,
    MaxAdminJSONBytes = State.max_admin_json_bytes,
    RateWindowSeconds = State.rate_window_seconds,
    MaxCallRequestsPerWindow = State.max_call_requests_per_window,
    MaxSessionSpawnsPerWindow = State.max_session_spawns_per_window,
    MaxWSCommandsPerWindow = State.max_ws_commands_per_window,
    LoadURIAllowedOrigins = State.load_uri_allowed_origins,
    RelationPatterns = State.relation_patterns,
    reverse(State.http_options_rev, HTTPOptions).


%!  collect_node_option(+Option, +State0, -State) is det.
collect_node_option(Option, State0, State) :-
    (   node_shared_db_source(Option, Source)
    ->  state_append_shared_db(State0, Source, State)
    ;   Option = sandbox(Mode)
    ->  state_set(State0, sandbox, Mode, State)
    ;   Option = profile(Profile)
    ->  state_set(State0, profile, Profile, State)
    ;   Option = auth(AuthMode)
    ->  state_set(State0, auth, AuthMode, State)
    ;   Option = dev_principal(PrincipalId)
    ->  state_set(State0, dev_principal, PrincipalId, State)
    ;   Option = dev_capabilities(Capabilities)
    ->  state_set(State0, dev_capabilities, Capabilities, State)
    ;   Option = owner(PrincipalId)
    ->  state_prepend(State0, principal_policies_rev, owner(PrincipalId), State)
    ;   Option = principal(PrincipalId, Capabilities)
    ->  state_prepend(State0, principal_policies_rev,
                      principal(PrincipalId, Capabilities), State)
    ;   Option = principal(PrincipalId, _Capabilities, _PrincipalProfile)
    ->  legacy_principal_profile_error(PrincipalId)
    ;   Option = timeout(Timeout)
    ->  state_set(State0, timeout, Timeout, State)
    ;   Option = cache_size(CacheSize)
    ->  state_set(State0, cache_size, CacheSize, State)
    ;   Option = max_inflight_calls(MaxInflightCalls)
    ->  state_set(State0, max_inflight_calls, MaxInflightCalls, State)
    ;   Option = max_sessions_per_principal(MaxSessionsPerPrincipal)
    ->  state_set(State0, max_sessions_per_principal,
                  MaxSessionsPerPrincipal, State)
    ;   Option = max_ws_actors_per_principal(MaxWSActorsPerPrincipal)
    ->  state_set(State0, max_ws_actors_per_principal,
                  MaxWSActorsPerPrincipal, State)
    ;   Option = max_term_text_bytes(MaxTermTextBytes)
    ->  state_set(State0, max_term_text_bytes, MaxTermTextBytes, State)
    ;   Option = max_load_text_bytes(MaxLoadTextBytes)
    ->  state_set(State0, max_load_text_bytes, MaxLoadTextBytes, State)
    ;   Option = max_ws_frame_bytes(MaxWSFrameBytes)
    ->  state_set(State0, max_ws_frame_bytes, MaxWSFrameBytes, State)
    ;   Option = max_admin_json_bytes(MaxAdminJSONBytes)
    ->  state_set(State0, max_admin_json_bytes, MaxAdminJSONBytes, State)
    ;   Option = rate_window_seconds(RateWindowSeconds)
    ->  state_set(State0, rate_window_seconds, RateWindowSeconds, State)
    ;   Option = max_call_requests_per_window(MaxCallRequestsPerWindow)
    ->  state_set(State0, max_call_requests_per_window,
                  MaxCallRequestsPerWindow, State)
    ;   Option = max_session_spawns_per_window(MaxSessionSpawnsPerWindow)
    ->  state_set(State0, max_session_spawns_per_window,
                  MaxSessionSpawnsPerWindow, State)
    ;   Option = max_ws_commands_per_window(MaxWSCommandsPerWindow)
    ->  state_set(State0, max_ws_commands_per_window,
                  MaxWSCommandsPerWindow, State)
    ;   Option = load_uri_allowed_origins(Origins)
    ->  state_set(State0, load_uri_allowed_origins, Origins, State)
    ;   Option = relations(RelationPatterns)
    ->  state_append_relations(State0, RelationPatterns, State)
    ;   state_prepend(State0, http_options_rev, Option, State)
    ).


state_set(State0, Key, Value, State) :-
    put_dict(Key, State0, Value, State).


state_prepend(State0, Key, Value, State) :-
    get_dict(Key, State0, Values0),
    put_dict(Key, State0, [Value|Values0], State).


state_append_shared_db(State0, Source, State) :-
    DB0 = State0.shared_db,
    append_source_text(DB0, Source, DB),
    put_dict(_{has_shared:true, shared_db:DB}, State0, State).


state_append_relations(State0, RelationPatterns, State) :-
    Relations0 = State0.relation_patterns,
    append(Relations0, RelationPatterns, Relations),
    put_dict(relation_patterns, State0, Relations, State).


legacy_principal_profile_error(PrincipalId) :-
    throw(error(domain_error(node_principal_profile, PrincipalId),
                context(node_startup_options:collect_node_option/3,
                        'principal-specific profiles are no longer supported; use principal(Id, Caps) and set the node profile separately'))).


%!  default_node_shared_db(-Source:string) is det.
%
%   Default node-wide shared database loaded when no explicit shared-db
%   startup options are provided.
default_node_shared_db(Source) :-
    default_node_shared_db_file(File),
    node_shared_db_source(load_shared_db_file(File), Source).


default_node_shared_db_file(File) :-
    source_file(node_startup_options:node_options(_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _),
                SourceFile),
    file_directory_name(SourceFile, Dir),
    directory_file_path(Dir, 'shared_db.pl', File).


%!  node_shared_db_source(+Option, -Source:string) is semidet.
%
%   Convert one shared-db startup option into source text.
node_shared_db_source(load_shared_db_text(Text0), Text) :-
    text_to_string(Text0, Text).
node_shared_db_source(load_shared_db_file(File0), Source) :-
    uri_atom(File0, File),
    setup_call_cleanup(
        open(File, read, Stream, [encoding(utf8)]),
        read_string(Stream, _, Source),
        close(Stream)).
node_shared_db_source(load_shared_db_uri(URI), Source) :-
    uri_to_source(URI, Source).
