:- module(node_tokens, [
    issue_token/4,             % +PrincipalId, +Capabilities, +Options, -FullToken
    verify_bearer_token/2,     % +TokenString, -Principal
    request_bearer_principal/2,% +Request, -Principal
    revoke_token/1,            % +TokenId
    current_tokens/1,          % -InfoList (no secrets/hashes)
    token_count/1,             % -Count
    clear_all_tokens/0,
    set_tokens_file/1,         % +Path  (configure on-disk persistence)
    current_tokens_file/1,     % -Path
    load_tokens/0,             % load the store from the configured file
    save_tokens/0              % flush the store to the configured file
]).

/** <module> Bearer API Tokens

A first-class authenticated identity source for clients that hit the node
directly, without an authenticating reverse proxy in front (CLI tools,
agents, scripts). A request carrying

    Authorization: Bearer wp_<id>_<secret>

is resolved to a `principal{id, capabilities, unknown:false}` exactly like
an `X-Web-Prolog-User` header — but, unlike that header, the token is
*proven*: the presented secret is checked against a stored hash. node_auth
tries this source before the (proxy-trusted) header.

The mechanism is opt-in and off by default: with no tokens issued, the
node behaves exactly as before.

Token shape `wp_<id>_<secret>`:
  - `<id>`     64 bits of CSPRNG, the public handle (safe to list/log);
  - `<secret>` 192 bits of CSPRNG, shown once at issue time, never stored.

Stored per token: a salted SHA-256 of the secret (so a leaked store
yields no usable tokens), the bound principal id + capability scope, and
expiry/revocation/audit timestamps. The full secret is returned only from
issue_token/4 and is unrecoverable thereafter.

Persistence: optional and off by default. With no file configured the
store is in-memory only (unchanged behavior; tests run this way). Once
`set_tokens_file/1` names a path, issue/revoke flush the store there
atomically and `load_tokens/0` reads it back at startup — so tokens
survive restarts. Only the salted hash is written, never a usable
secret; `last_used_at` is in-memory and resets on restart (it would cost
a disk write per request to persist).
*/

:- use_module(library(crypto)).
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(node_owner_tag, [secure_eq_text/2]).
:- use_module(node_capabilities, [normalize_capabilities/2]).

%   token_record(Id, Record) where Record is a dict:
%     hash:Hex, principal_id:String, capabilities:List,
%     created_at:Float, expires_at:Number (0 = no expiry),
%     last_used_at:Number (0 = never), revoked:Bool, label:String
:- dynamic token_record/2.
:- dynamic tokens_file_path/1.            % absolute path, when persistence is on


%!  issue_token(+PrincipalId, +Capabilities, +Options, -FullToken) is det.
%
%   Mint a token bound to PrincipalId with the given capability scope.
%   FullToken (`wp_<id>_<secret>`) is the only time the secret is
%   exposed. Options: `expires_in(Seconds)` or `expires_at(Epoch)` for an
%   expiry (default none); `label(Text)` for an operator note.
issue_token(PrincipalId0, Capabilities0, Options, FullToken) :-
    text_to_string(PrincipalId0, PrincipalId),
    PrincipalId \== "",
    normalize_capabilities(Capabilities0, Capabilities),
    get_time(Now),
    option_expires_at(Options, Now, ExpiresAt),
    ( memberchk(label(L0), Options) -> text_to_string(L0, Label) ; Label = "" ),
    with_mutex(node_tokens, (
        fresh_token_id(Id),
        fresh_secret(Secret),
        hash_secret(Id, Secret, Hash),
        Record = _{
            hash:Hash,
            principal_id:PrincipalId,
            capabilities:Capabilities,
            created_at:Now,
            expires_at:ExpiresAt,
            last_used_at:0,
            revoked:false,
            label:Label
        },
        assertz(token_record(Id, Record)),
        %  Keep memory and disk consistent: if the flush fails (e.g. an
        %  unwritable store), roll the new token back and fail loudly
        %  rather than hand out a token that won't survive a restart.
        catch(save_tokens, E, (retract(token_record(Id, Record)), throw(E)))
    )),
    format(string(FullToken), "wp_~w_~w", [Id, Secret]).

option_expires_at(Options, Now, ExpiresAt) :-
    (   memberchk(expires_at(T), Options), number(T)
    ->  ExpiresAt = T
    ;   memberchk(expires_in(Secs), Options), number(Secs)
    ->  ExpiresAt is Now + Secs
    ;   ExpiresAt = 0
    ).


%!  verify_bearer_token(+TokenString, -Principal) is semidet.
%
%   True when TokenString is a live (not revoked, not expired) token whose
%   secret matches; Principal is the bound principal{} dict. Touches the
%   token's last-used timestamp as a side effect.
verify_bearer_token(TokenString, principal{
                                  id:PrincipalId,
                                  capabilities:Capabilities,
                                  unknown:false
                              }) :-
    parse_token(TokenString, Id, Secret),
    token_record(Id, Record),
    get_dict(revoked, Record, false),
    token_not_expired(Record),
    get_dict(hash, Record, StoredHash),
    hash_secret(Id, Secret, PresentedHash),
    secure_eq_text(PresentedHash, StoredHash),
    get_dict(principal_id, Record, PrincipalId),
    get_dict(capabilities, Record, Capabilities),
    ignore(touch_last_used(Id)).

token_not_expired(Record) :-
    get_dict(expires_at, Record, ExpiresAt),
    (   ExpiresAt =:= 0
    ->  true
    ;   get_time(Now),
        Now < ExpiresAt
    ).


%!  request_bearer_principal(+Request, -Principal) is semidet.
%
%   Resolve a principal from a request's `Authorization: Bearer` header.
request_bearer_principal(Request, Principal) :-
    request_bearer_token(Request, TokenString),
    verify_bearer_token(TokenString, Principal).

request_bearer_token(Request, TokenString) :-
    memberchk(authorization(Value), Request),
    text_to_string(Value, Header),
    split_string(Header, " \t", " \t", Parts0),
    exclude(==(""), Parts0, [Scheme, TokenString|_]),
    string_lower(Scheme, Lower),
    Lower == "bearer".


%!  revoke_token(+TokenId) is semidet.
%
%   Mark a token revoked (kept for audit). True iff the id existed.
revoke_token(Id0) :-
    to_atom(Id0, Id),
    with_mutex(node_tokens, (
        retract(token_record(Id, Record))
    ->  put_dict(revoked, Record, true, Revoked),
        assertz(token_record(Id, Revoked)),
        catch(save_tokens, E,
              ( retract(token_record(Id, Revoked)),
                assertz(token_record(Id, Record)),
                throw(E) ))
    ;   fail
    )).


%!  current_tokens(-InfoList) is det.
%
%   All tokens as info dicts with the id but WITHOUT the hash — safe to
%   list in an admin view or log.
current_tokens(InfoList) :-
    findall(Info,
            ( token_record(Id, Record),
              del_dict(hash, Record, _, Rest),
              put_dict(_{id:Id}, Rest, Info)
            ),
            InfoList).


%!  token_count(-Count) is det.
token_count(Count) :-
    aggregate_all(count, token_record(_, _), Count).


%!  clear_all_tokens is det.
clear_all_tokens :-
    with_mutex(node_tokens, retractall(token_record(_, _))).


                 /*******************************
                 *         PERSISTENCE          *
                 *******************************/

%!  set_tokens_file(+Path) is det.
%
%   Turn on file persistence at Path (resolved to absolute). Does not
%   load — call load_tokens/0 after, typically once at startup.
set_tokens_file(Path0) :-
    absolute_file_name(Path0, Path, [access(none), file_errors(fail)]),
    with_mutex(node_tokens, (
        retractall(tokens_file_path(_)),
        assertz(tokens_file_path(Path))
    )).

%!  current_tokens_file(-Path) is semidet.
current_tokens_file(Path) :-
    tokens_file_path(Path).

%!  load_tokens is det.
%
%   Replace the in-memory store with the contents of the configured
%   file. No-op when no file is configured or it does not exist yet
%   (first run) — the in-memory store is left untouched.
load_tokens :-
    (   current_tokens_file(File),
        exists_file(File)
    ->  with_mutex(node_tokens, read_tokens_file(File))
    ;   true
    ).

read_tokens_file(File) :-
    retractall(token_record(_, _)),
    setup_call_cleanup(
        open(File, read, Stream, [encoding(utf8)]),
        read_token_clauses(Stream),
        close(Stream)).

read_token_clauses(Stream) :-
    read_term(Stream, Term, []),
    (   Term == end_of_file
    ->  true
    ;   assert_token_term(Term),
        read_token_clauses(Stream)
    ).

assert_token_term(token(Id, Hash, PrincipalId, Capabilities,
                        Created, Expires, Revoked, Label)) :-
    !,
    assertz(token_record(Id, _{
        hash:Hash,
        principal_id:PrincipalId,
        capabilities:Capabilities,
        created_at:Created,
        expires_at:Expires,
        last_used_at:0,
        revoked:Revoked,
        label:Label
    })).
assert_token_term(_).        % skip anything unexpected

%!  save_tokens is det.
%
%   Flush the store to the configured file, atomically (write a temp
%   file, then rename). No-op when no file is configured (in-memory
%   mode). Only the hash is written, never a usable secret.
save_tokens :-
    (   current_tokens_file(File)
    ->  with_mutex(node_tokens, write_tokens_file(File))
    ;   true
    ).

write_tokens_file(File) :-
    atom_concat(File, '.tmp', Tmp),
    setup_call_cleanup(
        open(Tmp, write, Stream, [encoding(utf8)]),
        forall(token_record(Id, Record),
               write_token_clause(Stream, Id, Record)),
        close(Stream)),
    rename_file(Tmp, File).

write_token_clause(Stream, Id, Record) :-
    Clause = token(Id,
                   Record.hash,
                   Record.principal_id,
                   Record.capabilities,
                   Record.created_at,
                   Record.expires_at,
                   Record.revoked,
                   Record.label),
    format(Stream, "~q.~n", [Clause]).


                 /*******************************
                 *           INTERNAL           *
                 *******************************/

fresh_token_id(Id) :-
    crypto_n_random_bytes(8, Bytes),
    hash_atom(Bytes, Id0),
    (   token_record(Id0, _)
    ->  fresh_token_id(Id)        % astronomically unlikely; retry to be safe
    ;   Id = Id0
    ).

fresh_secret(Secret) :-
    crypto_n_random_bytes(24, Bytes),
    hash_atom(Bytes, Secret).

%  Salt the hash with the (public) id so identical secrets — or a
%  precomputed table — never correlate across tokens.
hash_secret(Id, Secret, Hash) :-
    format(string(Data), "~w:~w", [Id, Secret]),
    crypto_data_hash(Data, Hash, [algorithm(sha256)]).

parse_token(Token0, Id, Secret) :-
    text_to_string(Token0, Token),
    split_string(Token, "_", "", ["wp", IdString, Secret]),
    IdString \== "",
    Secret \== "",
    atom_string(Id, IdString).

touch_last_used(Id) :-
    with_mutex(node_tokens, (
        (   retract(token_record(Id, Record))
        ->  get_time(Now),
            put_dict(last_used_at, Record, Now, Touched),
            assertz(token_record(Id, Touched))
        ;   true
        )
    )).

to_atom(X, A) :- ( atom(X) -> A = X ; atom_string(A, X) ).
