/** <file> start_node.pl — env-driven boot for a turn-key Web Prolog node

Reads configuration from environment variables, validates it, and
starts a node — or, with WP_CHECK=1, validates and exits without
binding a port (a deploy-time smoke test).

Secure by default:

  - WP_AUTH defaults to `private`.  Running a world-open node
    (WP_AUTH=open) additionally requires WP_ACK_PUBLIC=yes, so a public
    node is never started by accident.
  - WP_SANDBOX defaults to `blacklist` (deny a curated set of dangerous
    predicates, allow the rest) — the Web Prolog playground default, also
    the node's own default. Set WP_SANDBOX=whitelist for the stricter
    "reject anything not proven safe" policy on a hardened node.
  - Conservative limit defaults are baked in and overridable per knob.

Usage:

    swipl Deployment/start_node.pl        # reads env, starts, blocks
    WP_CHECK=1 swipl Deployment/start_node.pl   # validate config, exit

See Deployment/.env.example for the full variable list.
*/

:- initialization(main, main).

:- use_module(library(http/http_host), []).
:- use_module(library(http/thread_httpd), [http_stop_server/2]).
:- use_module(library(uri)).
:- use_module(library(settings)).
:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(yall)).

main :-
    catch(run, Error, report(Error)),
    !,
    halt(0).
main :-
    halt(2).                              % run failed without throwing

run :-
    load_web_prolog,
    load_config_file,
    resolve_config(Config),
    env_atom('WP_TOKENS_FILE', '', TokensFile),
    resolve_default_caps(DefaultCaps),
    resolve_ip_list('WP_IP_BLOCKLIST', IpBlock),
    resolve_ip_list('WP_IP_ALLOWLIST', IpAllow),
    anon_per_ip_flag(AnonPerIp),
    env_int('WP_AUTO_BAN_THRESHOLD', 0, AutoBanThreshold),
    env_int('WP_AUTO_BAN_WINDOW_SECONDS', 60, AutoBanWindow),
    env_int('WP_AUTO_BAN_SECONDS', 900, AutoBanSeconds),
    (   getenv('WP_CHECK', '1')
    ->  print_config(Config),
        print_tokens_config(TokensFile),
        print_default_caps(DefaultCaps),
        print_ip_lists(IpBlock, IpAllow),
        print_anon_per_ip(AnonPerIp),
        print_auto_ban(AutoBanThreshold, AutoBanWindow, AutoBanSeconds),
        format("~nConfiguration OK (WP_CHECK set; not binding a port).~n", [])
    ;   apply_public_url(Config),
        memberchk(port-Port, Config),
        memberchk(options-Options, Config),
        print_config(Config),
        print_tokens_config(TokensFile),
        print_default_caps(DefaultCaps),
        print_ip_lists(IpBlock, IpAllow),
        print_anon_per_ip(AnonPerIp),
        print_auto_ban(AutoBanThreshold, AutoBanWindow, AutoBanSeconds),
        setup_token_store(TokensFile),
        apply_default_caps(DefaultCaps),
        node_ip_policy:set_ip_blocklist(IpBlock),
        node_ip_policy:set_ip_allowlist(IpAllow),
        set_setting(node_auth:anon_per_ip, AnonPerIp),
        set_setting(node_ip_policy:auto_ban_threshold, AutoBanThreshold),
        set_setting(node_ip_policy:auto_ban_window_seconds, AutoBanWindow),
        set_setting(node_ip_policy:auto_ban_seconds, AutoBanSeconds),
        node(Port, Options),
        maybe_attach_discovery_hub(Port),
        install_drain_on_signal(Port),
        format("~nNode up on port ~w.~n", [Port]),
        flush_output,
        thread_get_message(drain),        % woken by the signal handler;
                                          % otherwise blocks forever (the
                                          % process is the unit of liveness)
        graceful_shutdown(Port)
    ).

%!  install_drain_on_signal(+Port) is det.
%
%   On SIGTERM/SIGINT (docker stop, systemctl stop, Ctrl-C), flip the
%   node into maintenance so /readyz drops to 503 and new work is
%   refused, then wake the main thread to drain and exit.  Standard
%   zero-downtime shutdown: the load balancer stops routing on the
%   readiness flip while in-flight work finishes during the grace
%   period.
:- dynamic drain_port/1.

install_drain_on_signal(Port) :-
    retractall(drain_port(_)),
    assertz(drain_port(Port)),
    on_signal(term, _, drain_signal),
    on_signal(int, _, drain_signal).

%  on_signal/3 calls the handler with the signal as its one argument,
%  so it must be an atom predicate name (not a curried compound); the
%  port comes from drain_port/1.
drain_signal(_Signal) :-
    ( drain_port(Port) -> catch(node_runtime_state:set_node_maintenance(Port, true), _, true) ; true ),
    catch(thread_send_message(main, drain), _, true).

%!  maybe_attach_discovery_hub(+Port) is det.
%
%   In discovery-hub mode, load the owner-local hub bootstrap and attach
%   the registry custodian to the node we just started (whose shared
%   database is already discovery_directory.pl).  A seed file
%   (WP_DISCOVERY_SEED_FILE — plain `seed_node/5.` facts) overrides the
%   built-in public seed.  No-op when the mode is off.
maybe_attach_discovery_hub(Port) :-
    ( discovery_hub_enabled
    ->  discovery_hub_path(HubFile),
        use_module(HubFile),
        ( env_atom('WP_DISCOVERY_SEED_FILE', '', SeedFile), SeedFile \== ''
        ->  discovery_hub:load_seed_file(SeedFile),
            format("  discovery seed: ~w~n", [SeedFile])
        ;   format("  discovery seed: built-in default~n", [])
        ),
        discovery_hub:attach_discovery_hub(Port),
        format("Discovery hub registry attached on port ~w.~n", [Port])
    ;   true
    ).

%!  setup_token_store(+File) is det.
%
%   Turn on bearer-token persistence at File and load any existing
%   tokens, so issued tokens survive restarts.  Empty ⇒ in-memory only.
setup_token_store('') :- !.
setup_token_store(File) :-
    node_tokens:set_tokens_file(File),
    node_tokens:load_tokens.

%!  resolve_default_caps(-Caps) is det.
%
%   The "registered" capability tier from WP_AUTHENTICATED_DEFAULT_CAPS
%   (comma-separated). Validated; admin and internal_transport are
%   refused as a blanket default — grant those per-principal only.
resolve_default_caps(Caps) :-
    csv_atoms('WP_AUTHENTICATED_DEFAULT_CAPS', Caps0),
    (   Caps0 == []
    ->  Caps = []
    ;   node_capabilities:normalize_capabilities(Caps0, Caps),
        forall(member(C, Caps), safe_default_cap(C))
    ).

safe_default_cap(C) :-
    (   memberchk(C, [admin, internal_transport])
    ->  throw(error(domain_error(safe_default_capability, C),
                    context(resolve_default_caps/1,
                            'admin / internal_transport cannot be a blanket authenticated tier; grant them per-principal')))
    ;   true
    ).

apply_default_caps([]) :- !.
apply_default_caps(Caps) :-
    set_setting(node_auth:authenticated_default_capabilities, Caps).

print_default_caps([]) :-
    !,
    format("  authenticated_default_caps: (none; unconfigured authenticated principals are denied)~n", []).
print_default_caps(Caps) :-
    format("  authenticated_default_caps: ~w  (the \"registered\" tier)~n", [Caps]).

%!  resolve_ip_list(+EnvName, -Patterns) is det.
%
%   IPv4 CIDRs / exact IPs from a comma-separated var; each validated so
%   a typo fails loudly rather than silently matching nothing.
resolve_ip_list(EnvName, Patterns) :-
    csv_atoms(EnvName, Patterns),
    forall(member(P, Patterns), valid_ip_pattern_or_throw(EnvName, P)).

valid_ip_pattern_or_throw(EnvName, Pattern) :-
    (   node_ip_policy:valid_ip_pattern(Pattern)
    ->  true
    ;   throw(error(domain_error(ip_pattern, Pattern),
                    context(resolve_ip_list/2,
                            EnvName)))
    ).

print_ip_lists([], []) :-
    !,
    format("  ip access control: (none)~n", []).
print_ip_lists(Block, Allow) :-
    ( Block == [] -> true ; format("  ip_blocklist: ~w~n", [Block]) ),
    ( Allow == [] -> true ; format("  ip_allowlist: ~w  (only these may execute)~n", [Allow]) ).

%!  anon_per_ip_flag(-Bool) is det.
%
%   WP_ANON_PER_IP (env / config): individualise the anonymous principal
%   per client IP, so it isn't one shared rate/limit/audit bucket.
anon_per_ip_flag(Bool) :-
    env_atom('WP_ANON_PER_IP', no, Value),
    ( memberchk(Value, [yes, true, on, '1']) -> Bool = true ; Bool = false ).

print_anon_per_ip(true) :-
    !,
    format("  anon_per_ip: on (anonymous is individualised per client IP)~n", []).
print_anon_per_ip(false) :-
    format("  anon_per_ip: off (shared anonymous principal)~n", []).

print_auto_ban(Threshold, _, _) :-
    Threshold =< 0,
    !,
    format("  auto_ban: off~n", []).
print_auto_ban(Threshold, Window, Seconds) :-
    format("  auto_ban: ~w rate-limit offenses / ~w s -> ban ~w s~n",
           [Threshold, Window, Seconds]).

print_tokens_config('') :-
    !,
    format("  tokens_file: (none; bearer tokens are in-memory only)~n", []).
print_tokens_config(File) :-
    format("  tokens_file: ~w~n", [File]).

graceful_shutdown(Port) :-
    env_int('WP_DRAIN_GRACE_SECONDS', 10, Grace),
    format("Draining (grace ~w s); /readyz now 503, refusing new work.~n", [Grace]),
    flush_output,
    catch(node_runtime_state:set_node_maintenance(Port, true), _, true),
    catch(sleep(Grace), _, true),
    catch(http_stop_server(Port, []), _, true),
    format("Drained; stopping.~n", []),
    flush_output,
    halt(0).

report(Error) :-
    (   message_text(Error, Text)
    ->  format(user_error, "web-prolog node failed to start:~n  ~w~n", [Text])
    ;   format(user_error, "web-prolog node failed to start:~n  ~q~n", [Error])
    ),
    halt(2).

message_text(Error, Text) :-
    prolog:message(Error, Parts, []),
    parts_text(Parts, Text).

parts_text(Parts, Text) :-
    with_output_to(string(Text),
        forall(member(P, Parts), emit_part(P))).

emit_part(nl) :- !, nl.
emit_part(Fmt-Args) :- !, format(Fmt, Args).
emit_part(Atom) :- format("~w", [Atom]).

%!  load_web_prolog is det.
%
%   Load library(web_prolog) whether started from a source checkout
%   (this file two levels under the repo root) or from an installed
%   pack (library/2 already resolves).
:- dynamic script_dir/1.
:- prolog_load_context(directory, D), asserta(script_dir(D)).

load_web_prolog :-
    %  Prefer the source tree this script ships in (Deployment/../prolog)
    %  so running from a checkout is predictable; otherwise rely on an
    %  installed library(web_prolog) pack.
    (   script_dir(Dir),
        atom_concat(Dir, '/../prolog/web_prolog.pl', Co0),
        absolute_file_name(Co0, Co, [access(read), file_errors(fail)])
    ->  atom_concat(Dir, '/../prolog', LibDir),
        asserta(user:file_search_path(library, LibDir)),
        use_module(Co)
    ;   use_module(library(web_prolog))
    ).


                /*******************************
                *        CONFIG RESOLUTION     *
                *******************************/

resolve_config([port-Port, public_url-PublicURL, options-Options]) :-
    env_int('WP_PORT', 3060, Port),
    env_atom('WP_PUBLIC_URL', '', PublicURL),
    one_of('WP_PROFILE', [relation, isobase, isotope, actor], actor, Profile),
    one_of('WP_AUTH', [open, dev, private], private, Auth),
    one_of('WP_SANDBOX', [whitelist, blacklist], blacklist, Sandbox),
    ack_public(Auth),
    env_int('WP_TIMEOUT', 10, Timeout),
    env_int('WP_MAX_INFLIGHT', 3, MaxInflight),
    env_int('WP_RATE_WINDOW', 60, RateWindow),
    env_int('WP_MAX_CALLS_PER_WINDOW', 120, MaxCalls),
    env_int('WP_MAX_TERM_BYTES', 32768, MaxTermBytes),
    env_int('WP_MAX_LOAD_TEXT_BYTES', 131072, MaxLoadTextBytes),
    %  Resource ceilings — bounded by default (a turn-key public node
    %  must survive one client's runaway goal). Set to 0 to disable.
    env_int('WP_MAX_ACTOR_STACK_BYTES', 268435456, MaxActorStackBytes),
    env_int('WP_MAX_CALL_INFERENCES', 1000000000, MaxCallInferences),
    env_int('WP_MAX_ACTORS', 10000, MaxActors),
    %  Interaction-log rotation — bound the durable JSONL on disk.
    env_int('WP_MAX_LOG_BYTES', 52428800, MaxLogBytes),
    env_int('WP_MAX_LOG_BACKUPS', 5, MaxLogBackups),
    csv_atoms('WP_WS_ALLOWED_ORIGINS', WsOrigins),
    csv_atoms('WP_LOAD_URI_ORIGINS', LoadUriOrigins),
    ws_origins_option(WsOrigins, WsOpts),
    load_uri_option(LoadUriOrigins, LoadUriOpts),
    owner_option(Auth, OwnerOpts),
    shared_db_option(SharedOpts),
    append([
        [ sandbox(Sandbox),
          profile(Profile),
          auth(Auth),
          timeout(Timeout),
          max_inflight_calls(MaxInflight),
          rate_window_seconds(RateWindow),
          max_call_requests_per_window(MaxCalls),
          max_term_text_bytes(MaxTermBytes),
          max_load_text_bytes(MaxLoadTextBytes),
          max_actor_stack_bytes(MaxActorStackBytes),
          max_call_inferences(MaxCallInferences),
          max_actors(MaxActors),
          max_interaction_log_bytes(MaxLogBytes),
          max_interaction_log_backups(MaxLogBackups)
        ],
        WsOpts,
        LoadUriOpts,
        OwnerOpts,
        SharedOpts
    ], Options).

%!  ack_public(+Auth) is det.
%
%   The secure-by-default gate: a world-open node must be opted into
%   explicitly, so WP_AUTH=open without WP_ACK_PUBLIC=yes is refused.
ack_public(open) :-
    !,
    (   getenv('WP_ACK_PUBLIC', yes)
    ->  true
    ;   throw(refuse_open_without_ack)
    ).
ack_public(_).

ws_origins_option([], []) :- !.
ws_origins_option(Origins, [ws_allowed_origins(Origins)]).

load_uri_option([], []) :- !.
load_uri_option(Origins, [load_uri_allowed_origins(Origins)]).

owner_option(private, [owner(Owner)]) :-
    getenv('WP_OWNER', Owner),
    Owner \== '',
    !.
owner_option(_, []).

%  An explicit WP_SHARED_DB_FILE always wins.  Otherwise, in discovery-hub
%  mode the node's shared database IS the hub's read side
%  (discovery_directory.pl), so the replica the registry publishes is
%  reachable over /call.
shared_db_option([load_shared_db_file(File)]) :-
    getenv('WP_SHARED_DB_FILE', File),
    File \== '',
    !.
shared_db_option([load_shared_db_file(File)]) :-
    discovery_hub_enabled,
    !,
    discovery_directory_path(File).
shared_db_option([]).


%!  discovery_hub_enabled is semidet.
%
%   True when WP_DISCOVERY_HUB opts this node into being a discovery hub
%   (n0): it serves discovery_directory.pl and runs the registry
%   custodian that probes the seed nodes and publishes the live register.
discovery_hub_enabled :-
    env_atom('WP_DISCOVERY_HUB', no, V),
    memberchk(V, [yes, true, on, '1']).

%!  discovery_directory_path(-File) is det.
%!  discovery_hub_path(-File) is det.
%
%   The example sources, resolved relative to this script
%   (Deployment/../examples/services/...), so they work from a checkout
%   and from the container image alike.
discovery_directory_path(File) :-
    example_service_file('discovery_directory.pl', File).

discovery_hub_path(File) :-
    example_service_file('discovery_hub.pl', File).

example_service_file(Name, File) :-
    script_dir(Dir),
    atomic_list_concat([Dir, '/../examples/services/', Name], Path),
    absolute_file_name(Path, File, [access(read)]).


                /*******************************
                *         PUBLIC URL           *
                *******************************/

%!  apply_public_url(+Config) is det.
%
%   When WP_PUBLIC_URL is set (the node sits behind a TLS-terminating
%   reverse proxy), advertise that URL via SWI's http:public_* settings
%   so self_node_url/1, cross-node addressing, and node-relative
%   load_uri resolve to the public name rather than localhost:Port.
apply_public_url(Config) :-
    memberchk(public_url-URL, Config),
    (   URL == ''
    ->  true
    ;   uri_components(URL, Components),
        uri_data(scheme, Components, Scheme),
        uri_data(authority, Components, Authority),
        uri_authority_components(Authority, AC),
        uri_authority_data(host, AC, Host),
        uri_authority_data(port, AC, Port0),
        ( integer(Port0) -> Port = Port0 ; default_scheme_port(Scheme, Port) ),
        set_setting(http:public_scheme, Scheme),
        set_setting(http:public_host, Host),
        set_setting(http:public_port, Port)
    ).

default_scheme_port(https, 443).
default_scheme_port(http, 80).


                /*******************************
                *         CONFIG FILE          *
                *******************************/

%  A declarative config file is the canonical surface; environment
%  variables override it per-knob (env > file > built-in default).
%  The file holds `key = Value.` Prolog terms, where `key` is the WP_*
%  variable name without the prefix, lowercased — e.g.
%
%      profile = actor.
%      auth = private.
%      public_url = 'https://node.example.com'.
%      max_actors = 10000.
%      ws_allowed_origins = ['https://node.example.com'].
%
%  Path: WP_CONFIG if set (and the file must then exist), else
%  ./web-prolog.conf if present, else no file.

:- dynamic config_value/2.

load_config_file :-
    retractall(config_value(_, _)),
    (   config_file_path(Path)
    ->  (   exists_file(Path)
        ->  read_config_terms(Path),
            assertz(config_value('$config_file', Path))
        ;   throw(config_file_missing(Path))
        )
    ;   true
    ).

config_file_path(Path) :-
    getenv('WP_CONFIG', Path0),
    Path0 \== '',
    !,
    Path = Path0.
config_file_path('web-prolog.conf') :-
    exists_file('web-prolog.conf').

read_config_terms(Path) :-
    setup_call_cleanup(
        open(Path, read, Stream),
        read_config_stream(Path, Stream),
        close(Stream)).

read_config_stream(Path, Stream) :-
    catch(read_term(Stream, Term, []),
          SyntaxError,
          throw(bad_config_syntax(Path, SyntaxError))),
    (   Term == end_of_file
    ->  true
    ;   (   Term = (Key = Value), atom(Key)
        ->  retractall(config_value(Key, _)),
            assertz(config_value(Key, Value))
        ;   throw(bad_config_term(Term))
        ),
        read_config_stream(Path, Stream)
    ).

config_lookup(EnvName, Value) :-
    env_to_config_key(EnvName, Key),
    config_value(Key, Value).

env_to_config_key(EnvName, Key) :-
    atom_concat('WP_', Rest, EnvName),
    downcase_atom(Rest, Key).


                /*******************************
                *         ENV HELPERS          *
                *******************************/

env_atom(Name, Default, Value) :-
    (   getenv(Name, A), A \== ''
    ->  Value = A
    ;   config_lookup(Name, V)
    ->  to_config_atom(V, Value)
    ;   Value = Default
    ).

to_config_atom(V, V) :- atom(V), !.
to_config_atom(V, A) :- atom_number(A, V), !.    % integer/float ⇒ atom
to_config_atom(V, A) :- term_to_atom(V, A).

env_int(Name, Default, Value) :-
    (   getenv(Name, A), A \== ''
    ->  (   atom_number(A, N), integer(N)
        ->  Value = N
        ;   throw(bad_integer_env(Name, A))
        )
    ;   config_lookup(Name, V)
    ->  (   integer(V)
        ->  Value = V
        ;   throw(bad_integer_config(Name, V))
        )
    ;   Value = Default
    ).

one_of(Name, Allowed, Default, Value) :-
    env_atom(Name, Default, V),
    (   memberchk(V, Allowed)
    ->  Value = V
    ;   throw(bad_enum_env(Name, V, Allowed))
    ).

csv_atoms(Name, Atoms) :-
    (   getenv(Name, A), A \== ''
    ->  parse_csv_atoms(A, Atoms)
    ;   config_lookup(Name, V)
    ->  (   is_list(V) -> Atoms = V ; parse_csv_atoms(V, Atoms) )
    ;   Atoms = []
    ).

parse_csv_atoms(A, Atoms) :-
    atom_string(A, S),
    split_string(S, ",", " \t", Parts0),
    exclude(==(""), Parts0, Parts),
    maplist([P,At]>>atom_string(At,P), Parts, Atoms).


                /*******************************
                *           OUTPUT             *
                *******************************/

print_config([port-Port, public_url-URL, options-Options]) :-
    format("web-prolog node configuration~n", []),
    ( config_value('$config_file', Path)
    -> format("  config file: ~w (env vars override)~n", [Path])
    ;  format("  config file: none (env vars + defaults)~n", []) ),
    format("  port:        ~w~n", [Port]),
    ( URL == '' -> true ; format("  public_url:  ~w~n", [URL]) ),
    forall(member(Opt, Options), print_option(Opt)).

print_option(Opt) :-
    Opt =.. [Name|Args],
    format("  ~w: ~w~n", [Name, Args]).

:- multifile prolog:message//1.

prolog:message(refuse_open_without_ack) -->
    [ 'WP_AUTH=open starts a world-open node that executes untrusted'-[], nl,
      'code from anyone on the network. To confirm this is intended,'-[], nl,
      'also set WP_ACK_PUBLIC=yes. Refusing to start.'-[] ].
prolog:message(bad_enum_env(Name, V, Allowed)) -->
    [ '~w=~w is not valid; expected one of ~w.'-[Name, V, Allowed] ].
prolog:message(bad_integer_env(Name, V)) -->
    [ '~w=~w is not an integer.'-[Name, V] ].
prolog:message(config_file_missing(Path)) -->
    [ 'WP_CONFIG points at ~w, which does not exist.'-[Path] ].
prolog:message(bad_config_term(Term)) -->
    [ 'config file has a bad entry: ~q (expected `key = Value.`).'-[Term] ].
prolog:message(bad_config_syntax(Path, _Error)) -->
    [ 'config file ~w has a syntax error (expected `key = Value.` terms).'-[Path] ].
prolog:message(bad_integer_config(Name, V)) -->
    [ 'config key for ~w is ~q, which is not an integer.'-[Name, V] ].
