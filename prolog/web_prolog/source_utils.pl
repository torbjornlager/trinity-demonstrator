:- module(source_utils,
   [ terms_to_source/2,         % +Terms, -Source
     predicates_to_source/3,    % +Module, +PIs, -Source
     text_to_string/2,          % +TextLike, -String
     uri_atom/2,                % +URI0, -URI
     normalize_load_uri_allowed_origins/2, % +Origins0, -Origins
     open_source_uri/2,         % +URI, -Stream
     source_uri_file/2,         % +URI, -File
     file_uri_fallback_path/2,  % +URI, -File
     uri_to_source/2,           % +URI, -Source
     uri_to_source_limited/3,   % +URI, +ByteLimit, -Source
     append_source_text/3       % +Left, +Right, -Combined
   ]).

/** <module> Source and URI Helpers (layer 1)

Utility predicates for turning different source representations into
plain text that can be loaded/consulted.  Extracted from the
demonstrator's source_utils.pl with its node dependencies replaced by
hooks:

  - load_uri_allowed_origins/1 (multifile): the node layer provides the
    configured HTTP(S) origin allowlist.  No clause, or the value
    `unrestricted`, means unrestricted fetching — the demonstrator's
    behavior outside a configured node.
  - self_base_url/1 (multifile): the distribution/node layer provides
    the node's own base URL for resolving node-relative URIs such as
    `statecharts/game.xml`.  Without it, relative URIs resolve only as
    local files.
*/

:- use_module(library(error)).
:- use_module(library(http/http_open)).
:- use_module(library(uri)).
:- use_module(library(utf8)).

:- multifile
    load_uri_allowed_origins/1,
    self_base_url/1.

%!  terms_to_source(+Terms:list, -Source:string) is det.
%
%   Convert a list of terms to textual Prolog source. Each term is written
%   using `~k` and terminated with `.` and newline, so the result can be fed
%   directly to `load_files/2` via a stream.
terms_to_source(Terms, Source) :-
    must_be(list, Terms),
    with_output_to(string(Source),
                   forall(member(Term, Terms),
                          format('~k .~n', [Term]))).

%!  predicates_to_source(+Module:atom, +PIs:list, -Source:string) is det.
%
%   Serialize the clauses of the listed predicate indicators from Module
%   using `listing/1`, producing textual source.
predicates_to_source(Module, PIs, Source) :-
    must_be(list, PIs),
    with_output_to(string(Source),
                   maplist(listing2(Module), PIs)).

%!  listing2(+Module:atom, +PI:callable) is det.
%
%   Helper used by predicates_to_source/3.
listing2(Module, PI) :-
    system:listing(Module:PI).

%!  text_to_string(+TextLike, -Text:string) is det.
%
%   Normalize atom/string/codes/chars input to a string.
text_to_string(Text, Text) :-
    string(Text),
    !.
text_to_string(Text0, Text) :-
    system:text_to_string(Text0, Text).

%!  uri_atom(+URI0, -URI:atom) is det.
%
%   Normalize URI/path input to atom form.
uri_atom(URI, URI) :-
    atom(URI),
    !.
uri_atom(URIString, URI) :-
    string(URIString),
    atom_string(URI, URIString).

%!  normalize_load_uri_allowed_origins(+Origins0, -Origins) is det.
%
%   Normalize configured allowlisted HTTP(S) origins to canonical
%   `scheme://host:port` atoms with default ports made explicit.
normalize_load_uri_allowed_origins(Origins0, Origins) :-
    must_be(list, Origins0),
    maplist(normalize_load_uri_allowed_origin, Origins0, Origins1),
    sort(Origins1, Origins).

normalize_load_uri_allowed_origin(Origin0, Origin) :-
    source_uri_origin(Origin0, Origin),
    !.
normalize_load_uri_allowed_origin(Origin, _) :-
    throw(error(domain_error(load_uri_origin, Origin),
                context(source_utils:normalize_load_uri_allowed_origins/2,
                        'load_uri allowed origins must be absolute HTTP(S) origins'))).

%!  open_source_uri(+URI, -Stream:stream) is det.
%
%   Open URI as UTF-8 text stream. If URI denotes a local file, use `open/4`.
%   Otherwise use `http_open/3`.
open_source_uri(URI0, Stream) :-
    resolve_source_uri(URI0, URI),
    enforce_source_uri_policy(URI0, URI),
    source_uri_file(URI, File),
    !,
    open(File, read, Stream, [encoding(utf8)]).
open_source_uri(URI0, Stream) :-
    resolve_source_uri(URI0, URI),
    open_http_source_uri(URI, Stream),
    set_stream(Stream, encoding(utf8)).

%!  source_uri_file(+URI:atom, -File:atom) is semidet.
%
%   True when URI designates a local file that exists.
%
%   Handles both:
%
%     - `file://...` URIs, and
%     - plain paths without URI scheme.
source_uri_file(URI, File) :-
    sub_atom(URI, 0, 7, _, 'file://'),
    !,
    (   uri_file_name(URI, File0)
    ->  File = File0
    ;   file_uri_fallback_path(URI, File)
    ),
    exists_file(File).
source_uri_file(URI, URI) :-
    \+ sub_atom(URI, _, 3, _, '://'),
    exists_file(URI).

%!  resolve_source_uri(+URI0, -URI) is det.
%
%   Resolve a source URI/path into either:
%
%     - a local file path,
%     - an absolute URI with scheme, or
%     - a node-relative HTTP(S) URI based on the node's base URL
%       (self_base_url/1, provided by an upper layer).
%
%   Relative URI forms such as `statecharts/game.xml` are resolved against the
%   current node base URL only when no local file of that name exists.
resolve_source_uri(URI0, URI) :-
    uri_atom(URI0, URI1),
    (   source_uri_file(URI1, _)
    ->  URI = URI1
    ;   sub_atom(URI1, _, 3, _, '://')
    ->  URI = URI1
    ;   resolve_node_relative_uri(URI1, URI)
    ).

resolve_node_relative_uri(Rel0, URI) :-
    self_base_url(Base0),
    !,
    normalize_relative_source_uri(Rel0, Rel),
    normalize_base_uri(Base0, Base),
    uri_resolve(Rel, Base, URI).
resolve_node_relative_uri(Rel, Rel).

normalize_relative_source_uri(Rel0, Rel) :-
    (   atom_concat('/', Rel1, Rel0)
    ->  Rel = Rel1
    ;   Rel = Rel0
    ).

normalize_base_uri(Base0, Base) :-
    (   sub_atom(Base0, _, 1, 0, '/')
    ->  Base = Base0
    ;   atom_concat(Base0, '/', Base)
    ).

%!  file_uri_fallback_path(+URI:atom, -File:atom) is det.
%
%   Fallback conversion for `file://` URIs when uri_file_name/2 cannot decode
%   the path on a given platform/input variation.
file_uri_fallback_path(URI, File) :-
    sub_atom(URI, 7, _, 0, Path0),
    (   sub_atom(Path0, 0, 1, _, '/')
    ->  File = Path0
    ;   exists_file(Path0)
    ->  File = Path0
    ;   atom_concat('/', Path0, File)
    ).

%!  uri_to_source(+URI, -Source:string) is det.
%
%   Read the full source text from URI/path into Source.
uri_to_source(URI0, Source) :-
    setup_call_cleanup(
        open_source_uri(URI0, Stream),
        read_string(Stream, _, Source),
        close(Stream)).

%!  uri_to_source_limited(+URI, +ByteLimit, -Source:string) is det.
%
%   Read the full source text from URI/path into Source while enforcing a
%   UTF-8 byte cap. This is intended for public request handling where source
%   fetching must not bypass node input limits.
uri_to_source_limited(URI0, ByteLimit, Source) :-
    must_be(integer, ByteLimit),
    (   ByteLimit > 0
    ->  true
    ;   throw(error(domain_error(not_less_than_one, ByteLimit),
                    context(source_utils:uri_to_source_limited/3,
                            'byte limit must be a positive integer')))
    ),
    setup_call_cleanup(
        open_source_uri(URI0, Stream),
        read_source_stream_limited(Stream, ByteLimit, Source),
        close(Stream)).

read_source_stream_limited(Stream, ByteLimit, Source) :-
    read_source_stream_limited(Stream, ByteLimit, 0, "", Source).

read_source_stream_limited(Stream, ByteLimit, Size0, Acc0, Source) :-
    read_string(Stream, 4096, Chunk),
    (   Chunk == ""
    ->  Source = Acc0
    ;   utf8_text_size(Chunk, ChunkSize),
        Size is Size0 + ChunkSize,
        (   Size =< ByteLimit
        ->  string_concat(Acc0, Chunk, Acc),
            read_source_stream_limited(Stream, ByteLimit, Size, Acc, Source)
        ;   throw(error(request_size_exceeded(load_uri, Size, ByteLimit),
                        context(source_utils:uri_to_source_limited/3,
                                'fetched source exceeded the configured size limit')))
        )
    ).

utf8_text_size(Text0, Size) :-
    string_codes(Text0, Codes),
    phrase(utf8_codes(Codes), UTF8Bytes),
    length(UTF8Bytes, Size).

current_load_uri_allowed_origins(Origins) :-
    load_uri_allowed_origins(Origins0),
    Origins0 \== unrestricted,
    Origins = Origins0.

enforce_source_uri_policy(_URI0, URI) :-
    \+ current_load_uri_allowed_origins(_),
    !,
    URI = URI.
enforce_source_uri_policy(URI0, URI) :-
    current_load_uri_allowed_origins(AllowedOrigins),
    source_uri_origin(URI, Origin),
    !,
    (   memberchk(Origin, AllowedOrigins)
    ->  true
    ;   throw(error(permission_error(load, source_uri, URI0),
                    context(source_utils:open_source_uri/2,
                            'load_uri target origin is not on the configured allowlist')))
    ).
enforce_source_uri_policy(URI0, _URI) :-
    throw(error(permission_error(load, source_uri, URI0),
                context(source_utils:open_source_uri/2,
                        'load_uri target must resolve to an allowlisted HTTP(S) origin'))).

open_http_source_uri(URI, Stream) :-
    (   current_load_uri_allowed_origins(AllowedOrigins)
    ->  open_http_source_uri_allowed(URI, AllowedOrigins, 0, Stream)
    ;   http_open(URI, Stream, [])
    ).

open_http_source_uri_allowed(URI, AllowedOrigins, RedirectDepth, Stream) :-
    http_open(URI, Stream0,
              [ redirect(false),
                status_code(StatusCode),
                header(location, Location)
              ]),
    (   redirect_status_code(StatusCode)
    ->  close(Stream0),
        (   Location == ''
        ->  throw(error(existence_error(http_header, location),
                        context(source_utils:open_source_uri/2,
                                'redirect response did not include a Location header')))
        ;   uri_resolve(Location, URI, RedirectedURI),
            ensure_redirect_allowed(URI, RedirectedURI, AllowedOrigins),
            NextDepth is RedirectDepth + 1,
            (   NextDepth =< 10
            ->  open_http_source_uri_allowed(RedirectedURI, AllowedOrigins,
                                             NextDepth, Stream)
            ;   throw(error(permission_error(redirect, source_uri, RedirectedURI),
                            context(source_utils:open_source_uri/2,
                                    'load_uri redirect chain exceeded the maximum depth')))
            )
        )
    ;   StatusCode >= 200,
        StatusCode < 300
    ->  Stream = Stream0
    ;   close(Stream0),
        throw(error(existence_error(source_uri, URI),
                    context(source_utils:open_source_uri/2,
                            'load_uri fetch failed')))
    ).

redirect_status_code(301).
redirect_status_code(302).
redirect_status_code(303).
redirect_status_code(307).
redirect_status_code(308).

ensure_redirect_allowed(_URI, RedirectedURI, AllowedOrigins) :-
    source_uri_origin(RedirectedURI, Origin),
    memberchk(Origin, AllowedOrigins),
    !.
ensure_redirect_allowed(_URI, RedirectedURI, _AllowedOrigins) :-
    throw(error(permission_error(redirect, source_uri, RedirectedURI),
                context(source_utils:open_source_uri/2,
                        'load_uri redirect target origin is not on the configured allowlist'))).

source_uri_origin(URI0, Origin) :-
    uri_atom(URI0, URI1),
    uri_normalized(URI1, URI),
    uri_components(URI, Components),
    uri_data(scheme, Components, Scheme),
    memberchk(Scheme, [http, https]),
    uri_data(authority, Components, Authority),
    nonvar(Authority),
    Authority \== '',
    uri_authority_components(Authority, AuthorityComponents),
    uri_authority_data(host, AuthorityComponents, Host),
    Host \== '',
    uri_authority_data(port, AuthorityComponents, Port0),
    normalized_origin_port(Scheme, Port0, Port),
    format(atom(Origin), '~w://~w:~w', [Scheme, Host, Port]).

normalized_origin_port(http, Port0, Port) :-
    (   var(Port0)
    ->  Port = 80
    ;   Port = Port0
    ).
normalized_origin_port(https, Port0, Port) :-
    (   var(Port0)
    ->  Port = 443
    ;   Port = Port0
    ).

%!  append_source_text(+Left, +Right, -Combined) is det.
%
%   Concatenate source fragments with a guaranteed separator so term
%   boundaries cannot be accidentally fused (`... .wife(...)`).
append_source_text("", Right, Right) :- !.
append_source_text(Left, "", Left) :- !.
append_source_text(Left, Right, Combined) :-
    string_concat(Left, "\n", WithSep),
    string_concat(WithSep, Right, Combined).
