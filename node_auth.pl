:- module(node_auth, [
    auth_mode/1,
    normalize_auth_mode/2,
    set_dev_auth_config/2,
    request_principal/2,
    ws_principal/2,
    principal_id/2,
    principal_from_id/2,
    principal_capabilities/2,
    principal_has_capability/2,
    principal_execution_authorized/1,
    require_execution_access/1,
    require_admin_access/1,
    require_capability/2,
    require_any_capability/2,
    require_route_access/2,
    require_ws_command_access/2,
    require_source_text_access/2,
    require_source_options_access/2
]).

/** <module> Authentication and Authorization Policy

Identity extraction plus authorization checks for execution, admin access,
and ownership.
*/

:- use_module(library(error)).
:- use_module(library(random)).
:- use_module(library(settings)).

:- use_module(node_client, [text_to_string/2]).
:- use_module(node_capabilities, [
    normalize_capability/2,
    normalize_capabilities/2,
    capability_granted/2
]).
:- use_module(node_runtime_state, [current_node_value/2]).
:- use_module(node_principal_policy, [principal_policy/2]).

:- setting(auth, atom, open, 'Authorization mode: open, private, or dev').

:- dynamic dev_auth_config/2.


%!  auth_mode(-Mode) is det.
auth_mode(Mode) :-
    (   current_node_value(auth, Mode1)
    ->  Mode0 = Mode1
    ;   setting(auth, Mode0)
    ),
    normalize_auth_mode(Mode0, Mode).


%!  normalize_auth_mode(+Mode0, -Mode) is det.
normalize_auth_mode(off, open) :-
    !.
normalize_auth_mode(public, open) :-
    !.
normalize_auth_mode(development, dev) :-
    !.
normalize_auth_mode(Mode, Mode) :-
    valid_auth_mode(Mode),
    !.
normalize_auth_mode(Mode, _) :-
    throw(error(domain_error(node_auth_mode, Mode),
                context(node_auth:normalize_auth_mode/2,
                        'auth mode must be open, private, dev, off, public, or development'))).


valid_auth_mode(open).
valid_auth_mode(private).
valid_auth_mode(dev).


%!  set_dev_auth_config(+PrincipalId, +Capabilities) is det.
set_dev_auth_config(PrincipalId0, Capabilities0) :-
    normalize_dev_principal_id(PrincipalId0, PrincipalId),
    normalize_dev_capabilities(Capabilities0, Capabilities),
    retractall(dev_auth_config(_, _)),
    assertz(dev_auth_config(PrincipalId, Capabilities)).


%!  request_principal(+Request, -Principal) is det.
request_principal(Request, Principal) :-
    auth_mode(Mode),
    (   request_authenticated_principal(Request, Principal0)
    ->  Principal = Principal0
    ;   Mode == dev,
        request_dev_principal(Request, Principal1)
    ->  Principal = Principal1
    ;   Principal = anonymous
    ).


%!  ws_principal(+Request, -Principal) is det.
%
%   Resolve the principal for a WebSocket handshake.  Same as
%   request_principal/2 by default, but when the node's
%   `anon_per_ws_connection` runtime value is true the shared
%   `anonymous` principal is replaced with a fresh per-connection
%   `anon:<id>` principal.
%
%   Why per-connection: with the default shared anonymous principal,
%   all unauthenticated browser visitors collapse to one identity, so
%   per-principal limits like max_ws_actors_per_principal degenerate
%   into a single shared bucket (one visitor saturates the cap for
%   everyone), audit log rows lose meaning, and there is no way to
%   rate-shape a specific misbehaving client.  Individualising the
%   id at handshake time restores per-tab isolation without
%   requiring an authentication UX.
%
%   The id is server-generated and only meaningful for the lifetime
%   of the WebSocket connection.  No cookie, no signing.  A
%   sufficiently-trusted client cannot forge another tab's id
%   because the id never leaves the server for the wire identity --
%   only the WS connection itself binds an actor to its principal.
ws_principal(Request, Principal) :-
    request_principal(Request, Base),
    (   ws_should_individualize_anon(Base)
    ->  individualize_anon_principal(Principal)
    ;   Principal = Base
    ).

ws_should_individualize_anon(anonymous) :-
    catch(current_node_value(anon_per_ws_connection, true), _, fail),
    !.

individualize_anon_principal(principal{
                                id:Id,
                                capabilities:Capabilities,
                                unknown:false
                            }) :-
    auth_mode(Mode),
    anonymous_capabilities(Mode, Capabilities),
    fresh_anon_principal_id(Id).

fresh_anon_principal_id(Id) :-
    %  64 bits of random in lowercase hex, prefixed `anon:` so the
    %  audit / dev paths can recognise it as an anonymous identity.
    %  Not cryptographic; only collision-resistance and forge-
    %  resistance-by-non-disclosure matter here.
    random_between(0, 18446744073709551615, N),
    format(string(Id), "anon:~|~`0t~16r~16+", [N]).


%!  principal_id(+Principal, -PrincipalId) is det.
principal_id(anonymous, anonymous) :-
    !.
principal_id(Principal, PrincipalId) :-
    is_dict(Principal, principal),
    get_dict(id, Principal, PrincipalId).

%!  principal_from_id(+PrincipalId, -Principal) is det.
principal_from_id(anonymous, anonymous) :-
    !.
principal_from_id(PrincipalId0, principal{
                                 id:PrincipalId,
                                 capabilities:Capabilities,
                                 unknown:Unknown
                             }) :-
    text_to_string(PrincipalId0, PrincipalId),
    (   principal_policy(PrincipalId, Capabilities)
    ->  Unknown = false
    ;   auth_mode(dev),
        dev_auth_principal_config(PrincipalId, Capabilities)
    ->  Unknown = false
    ;   Capabilities = [],
        Unknown = true
    ).


principal_unknown(Principal) :-
    is_dict(Principal, principal),
    get_dict(unknown, Principal, true).


%!  principal_capabilities(+Principal, -Capabilities) is det.
principal_capabilities(anonymous, Capabilities) :-
    !,
    auth_mode(Mode),
    anonymous_capabilities(Mode, Capabilities).
principal_capabilities(Principal, []) :-
    principal_unknown(Principal),
    !.
principal_capabilities(Principal, Capabilities) :-
    is_dict(Principal, principal),
    get_dict(capabilities, Principal, Capabilities0),
    sort(Capabilities0, Capabilities).


%!  principal_has_capability(+Principal, +Capability) is semidet.
principal_has_capability(Principal, Capability) :-
    principal_capabilities(Principal, Capabilities),
    capability_granted(Capabilities, Capability).


%!  principal_execution_authorized(+Principal) is semidet.
principal_execution_authorized(Principal) :-
    principal_capabilities(Principal, Capabilities),
    capability_granted(Capabilities, execute).


%!  require_execution_access(+Principal) is det.
require_execution_access(Principal) :-
    reject_unknown_principal(Principal, node_auth:require_execution_access/1),
    (   principal_execution_authorized(Principal)
    ->  true
    ;   principal_id(Principal, PrincipalId),
        throw(error(authorization_error(PrincipalId, execution),
                    context(node_auth:require_execution_access/1,
                            'principal is not authorized for node execution')))
    ).


%!  require_admin_access(+Request) is det.
require_admin_access(Request) :-
    request_principal(Request, Principal),
    (   principal_has_capability(Principal, admin)
    ->  true
    ;   auth_mode(Mode),
        Mode == open,
        admin_request_is_local(Request)
    ->  true
    ;   require_capability(Principal, admin)
    ).


%!  require_capability(+Principal, +Capability) is det.
require_capability(Principal, Capability) :-
    reject_unknown_principal(Principal, node_auth:require_capability/2),
    principal_capabilities(Principal, Capabilities),
    (   capability_granted(Capabilities, Capability)
    ->  true
    ;   principal_id(Principal, PrincipalId),
        throw(error(authorization_error(PrincipalId, capability(Capability)),
                    context(node_auth:require_capability/2,
                            'principal lacks the required capability')))
    ).


%!  require_any_capability(+Principal, +Capabilities) is det.
require_any_capability(Principal, Capabilities) :-
    must_be(list, Capabilities),
    reject_unknown_principal(Principal, node_auth:require_any_capability/2),
    principal_capabilities(Principal, Granted),
    (   member(Capability, Capabilities),
        capability_granted(Granted, Capability)
    ->  true
    ;   principal_id(Principal, PrincipalId),
        throw(error(authorization_error(PrincipalId, any_capability(Capabilities)),
                    context(node_auth:require_any_capability/2,
                            'principal lacks any acceptable capability')))
    ).


%!  require_route_access(+Principal, +RouteId) is det.
require_route_access(Principal, _RouteId) :-
    require_execution_access(Principal).


%!  require_ws_command_access(+Principal, +Command) is det.
require_ws_command_access(Principal, _Command) :-
    require_execution_access(Principal).


%!  require_source_text_access(+Principal, +SourceText) is det.
require_source_text_access(_Principal, SourceText0) :-
    text_to_string(SourceText0, SourceText),
    normalize_space(string(Normalized), SourceText),
    Normalized == "",
    !.
require_source_text_access(Principal, _) :-
    require_execution_access(Principal).


%!  require_source_options_access(+Principal, +Options) is det.
require_source_options_access(Principal, Options) :-
    must_be(list, Options),
    maplist(require_source_option_access(Principal), Options).


request_authenticated_principal(Request, principal{
                                   id:PrincipalId,
                                   capabilities:Capabilities,
                                   unknown:Unknown
                               }) :-
    request_header_value(Request,
                         [x_web_prolog_user, x_web_prolog_principal, x_authenticated_user],
                         PrincipalId0),
    normalize_header_string(PrincipalId0, PrincipalId),
    PrincipalId \== "",
    (   internal_transport_principal(Request, PrincipalId, Capabilities)
    ->  Unknown = false
    ;   authenticated_principal_policy(PrincipalId, Capabilities, Unknown)
    ).

authenticated_principal_policy(PrincipalId, Capabilities, Unknown) :-
    (   principal_policy(PrincipalId, PolicyCapabilities)
    ->  Capabilities = PolicyCapabilities,
        Unknown = false
    ;   Capabilities = [],
        Unknown = true
    ).


internal_transport_principal(Request, PrincipalId, Capabilities) :-
    sub_string(PrincipalId, 0, 5, _, "node:"),
    request_internal_transport_trusted(Request),
    request_capabilities_header(Request, Capabilities),
    memberchk(internal_transport, Capabilities).


%!  request_internal_transport_trusted(+Request) is semidet.
%
%   Decide whether a request may claim the `internal_transport`
%   capability via its `X-Web-Prolog-*` headers.
%
%   The trust boundary is the peer's network position.  A direct
%   loopback or RFC1918 private peer is trusted on its own; the
%   `X-Web-Prolog-Internal-Proxy: true` header is treated only as a
%   defence-in-depth signal that a header-stripping reverse proxy
%   has approved this request -- it is not sufficient on its own.
%
%   Why the header is not sufficient: a node whose HTTP port is
%   reachable from the internet without a reverse proxy that
%   strips the `X-Web-Prolog-*` headers from inbound traffic would
%   otherwise grant `internal_transport` to anyone who sets the
%   header.  Requiring private/loopback peer in addition closes
%   that hole for misconfigured deployments while keeping the
%   intended Caddy-in-private-docker-network path working (Caddy's
%   peer IP is in the private network range, AND Caddy sets the
%   proxy header).
request_internal_transport_trusted(Request) :-
    request_is_local(Request),
    !.
request_internal_transport_trusted(Request) :-
    request_is_private_network(Request),
    !.


request_capabilities_header(Request, Capabilities) :-
    request_header_value(Request,
                         [x_web_prolog_capabilities, x_web_prolog_caps],
                         Value),
    parse_capability_header(Value, Capabilities).


request_header_value(Request, [Name|_], Value) :-
    request_header_value_1(Request, Name, Value),
    !.
request_header_value(Request, [_|Names], Value) :-
    request_header_value(Request, Names, Value).


request_header_value_1(Request, Name, Value) :-
    Term =.. [Name, Value],
    memberchk(Term, Request).


normalize_header_string(Value0, Value) :-
    text_to_string(Value0, Value1),
    normalize_space(string(Value), Value1).


parse_capability_header(Value0, Capabilities) :-
    normalize_header_string(Value0, Value),
    (   Value == ""
    ->  Capabilities0 = []
    ;   split_string(Value, ",", " \t\r\n", Parts0),
        exclude(==(""), Parts0, Parts),
        maplist(header_capability, Parts, Capabilities0)
    ),
    sort([public_read|Capabilities0], Capabilities).


header_capability(Part, Capability) :-
    normalize_capability(Part, Capability),
    !.
header_capability(Part, _) :-
    throw(error(domain_error(node_capability, Part),
                context(node_auth:parse_capability_header/2,
                        'capability header contains an unknown capability'))).


reject_unknown_principal(Principal, Context) :-
    (   principal_unknown(Principal)
    ->  principal_id(Principal, PrincipalId),
        throw(error(authorization_error(PrincipalId, principal(PrincipalId)),
                    context(Context,
                            'authenticated principal is unknown to the node policy')))
    ;   true
    ).


require_source_option_access(Principal, load_text(SourceText)) :-
    !,
    require_source_text_access(Principal, SourceText).
require_source_option_access(Principal, load_list(_Terms)) :-
    !,
    require_execution_access(Principal).
require_source_option_access(Principal, load_predicates(_PIs)) :-
    !,
    require_execution_access(Principal).
require_source_option_access(Principal, load_uri(_URI)) :-
    !,
    require_execution_access(Principal).
require_source_option_access(_, _).


anonymous_capabilities(open, Capabilities) :-
    default_open_capabilities(Capabilities).
anonymous_capabilities(private, [public_read]).
anonymous_capabilities(dev, [public_read]).


default_open_capabilities([
    public_read,
    execute
]).

default_dev_principal_id("dev").

%  Default dev capabilities used to be [admin].  That was a foot-gun
%  because `admin` should never be the implicit default for a mode
%  that grants by peer IP alone -- launching `auth(dev)` without
%  explicitly setting `dev_capabilities([...])` then gave every
%  loopback request full admin.  Defaulted to [execute] so the
%  dev-auth path is safe-by-default; admin must be opted into
%  explicitly via the `dev_capabilities([admin])` startup option.
default_dev_capabilities([execute]).


%!  request_dev_principal(+Request, -Principal) is semidet.
%
%   Loopback shortcut used only when the node was started with
%   `auth(dev)`.  Grants the configured dev principal id and
%   capabilities to any request whose HTTP peer address is local.
%
%   Security note: "peer" is whatever the HTTP layer sees as the
%   TCP peer.  If a node is fronted by a reverse proxy running on
%   the same host (e.g. Caddy/nginx on 127.0.0.1 -> SWI HTTP on
%   127.0.0.1), the peer is loopback for *every* external client
%   and `auth(dev)` would hand the dev principal to the entire
%   internet.  Unlike `internal_transport` (see
%   request_internal_transport_trusted/1), this path does NOT
%   require an additional defence-in-depth header.  `auth(dev)`
%   should therefore only be used for direct loopback access -- not
%   in conjunction with a same-host reverse proxy.
request_dev_principal(Request, principal{
                         id:PrincipalId,
                         capabilities:Capabilities
                     }) :-
    request_is_local(Request),
    dev_auth_principal_config(PrincipalId, Capabilities).


request_is_local(Request) :-
    memberchk(peer(Peer), Request),
    local_request_peer(Peer),
    !.


request_is_private_network(Request) :-
    memberchk(peer(Peer), Request),
    private_request_peer(Peer),
    !.


admin_request_is_local(Request) :-
    request_is_local(Request),
    !.
admin_request_is_local(Request) :-
    request_targets_loopback_host(Request),
    !.
admin_request_is_local(Request) :-
    request_is_private_network(Request),
    request_targets_loopback_host(Request).


request_targets_loopback_host(Request) :-
    request_header_value(Request, [host], HostValue0),
    normalize_header_string(HostValue0, HostValue1),
    string_lower(HostValue1, HostValue),
    loopback_host_header(HostValue).


loopback_host_header("localhost").
loopback_host_header("127.0.0.1").
loopback_host_header("::1").
loopback_host_header("[::1]").
loopback_host_header(Host) :-
    sub_string(Host, 0, _, _, "localhost:").
loopback_host_header(Host) :-
    sub_string(Host, 0, _, _, "127.0.0.1:").
loopback_host_header(Host) :-
    sub_string(Host, 0, _, _, "[::1]:").


local_request_peer(Host:_Port) :-
    !,
    local_request_peer(Host).
local_request_peer(ip(127, 0, 0, 1)).
local_request_peer(ip(0, 0, 0, 0, 0, 0, 0, 1)).
local_request_peer(Peer) :-
    (   atom(Peer)
    ;   string(Peer)
    ),
    text_to_string(Peer, Text),
    memberchk(Text, ["127.0.0.1", "::1", "localhost"]).


private_request_peer(Host:_Port) :-
    !,
    private_request_peer(Host).
private_request_peer(ip(10, _, _, _)).
private_request_peer(ip(172, B, _, _)) :-
    between(16, 31, B).
private_request_peer(ip(192, 168, _, _)).
private_request_peer(ip(127, 0, 0, 1)).
private_request_peer(ip(0, 0, 0, 0, 0, 0, 0, 1)).
private_request_peer(Peer) :-
    (   atom(Peer)
    ;   string(Peer)
    ),
    text_to_string(Peer, Text),
    (   sub_string(Text, 0, 3, _, "10.")
    ;   sub_string(Text, 0, 8, _, "192.168.")
    ;   sub_string(Text, 0, 10, _, "127.0.0.1")
    ;   sub_string(Text, 0, 3, _, "::1")
    ;   split_string(Text, ".", "", ["172", BStr | _]),
        catch(number_string(B, BStr), _, fail),
        between(16, 31, B)
    ).


dev_auth_principal_config(PrincipalId, Capabilities) :-
    (   current_node_value(dev_principal, PrincipalId0),
        current_node_value(dev_capabilities, Capabilities0)
    ->  PrincipalId = PrincipalId0,
        Capabilities = Capabilities0
    ;   dev_auth_config(PrincipalId0, Capabilities0)
    ->  PrincipalId = PrincipalId0,
        Capabilities = Capabilities0
    ;   default_dev_principal_id(PrincipalId),
        default_dev_capabilities(Capabilities)
    ).


normalize_dev_principal_id(PrincipalId0, PrincipalId) :-
    text_to_string(PrincipalId0, PrincipalId),
    PrincipalId \== "",
    !.
normalize_dev_principal_id(PrincipalId, _) :-
    throw(error(domain_error(dev_principal_id, PrincipalId),
                context(node_auth:set_dev_auth_config/2,
                        'dev principal id must be a non-empty atom or string'))).


normalize_dev_capabilities(Capabilities0, Capabilities) :-
    normalize_capabilities(Capabilities0, Capabilities1),
    sort(Capabilities1, Capabilities).
