:- module(domain_origins, [demonstrator_domain_origins/1, demonstrator_transport_options/1,
                          demonstrator_n2_rpc_endpoints/1]).
:- use_module(library(readutil)).
:- use_module(library(uri)).

% Compose opts into its private service topology; local development retains
% the public endpoint unless the owner explicitly configures this variable.
demonstrator_n2_rpc_endpoints(Endpoints) :-
    (getenv('WP_N2_N4_RPC_ENDPOINT', Endpoint), Endpoint \== '' ->
        (catch(valid_rpc_origin(Endpoint),_,fail)
        -> Endpoints=['https://n4.elfenbenstornet.se'-Endpoint]
        ; throw(error(domain_error(rpc_endpoint_configuration,'WP_N2_N4_RPC_ENDPOINT'),
                      demonstrator_n2_rpc_endpoints/1)))
    ;Endpoints=[]).

valid_rpc_origin(Endpoint) :-
    uri_components(Endpoint,uri_components(Scheme,Authority,Path,Query,Fragment)),
    memberchk(Scheme,[http,https]),atom(Authority),Authority\=='',
    memberchk(Path,['','/']),var(Query),var(Fragment),
    uri_authority_components(Authority,uri_authority(User,Password,Host,Port)),
    var(User),var(Password),atom(Host),Host\=='',
    \+ (sub_atom(Host,_,1,_,C),char_type(C,space)),
    (var(Port);integer(Port),between(1,65535,Port)).

% All deployed nodes in the demonstrator's domain belong to the same federation.
% Keep public source/spawn and browser-origin admission consistent. This grants
% origin permission, not a different execution profile or a private-node login.
% Peer transports must still authenticate; N7's public visitors remain isolated.
demonstrator_domain_origins(Origins) :-
    findall(Origin,
            ( between(0, 7, N),
              format(atom(Origin), 'https://n~d.elfenbenstornet.se', [N]) ),
            Origins).

% The owner already mounts this file and sets the environment variable. Read
% it once at startup so distribution can send the existing peer credentials.
% Configuration errors name the file, never a token or its parsed contents.
demonstrator_transport_options(Options) :-
    outgoing_transport_options(Outgoing),
    inbound_transport_options(Inbound),
    append(Outgoing, Inbound, Options).

outgoing_transport_options(Options) :-
    ( getenv('WP_PEER_TRANSPORT_TOKENS_FILE', File), File \== '' ->
        ( catch(read_file_to_terms(File, [Pairs], []), _, fail),
          ground(Pairs), acyclic_term(Pairs), is_list(Pairs),
          demonstrator_domain_origins(Origins),
          forall(member(Origin-Token, Pairs),
                 ( memberchk(Origin, Origins), atom(Token),
                   atom_length(Token, Length), Length >= 24,
                   atom_codes(Token, Codes),
                   \+ memberchk(10, Codes), \+ memberchk(13, Codes) )),
          forall(member(Pair, Pairs), Pair = (_-_))
        -> Options = [peer_transport_tokens(Pairs)]
        ; throw(error(domain_error(peer_transport_configuration, File),
                      demonstrator_transport_options/1)) )
    ; Options = [] ).

% Owner-installed inbound transport credentials are immutable configuration;
% provisioning them does not rewrite the mutable token store of a live node.
inbound_transport_options(Options) :-
    ( getenv('WP_PEER_INBOUND_TOKENS_FILE', File), File \== '' ->
        ( catch(read_file_to_terms(File, [Pairs], []), _, fail),
          ground(Pairs), acyclic_term(Pairs), is_list(Pairs),
          demonstrator_domain_origins(Origins),
          forall(member(Pair, Pairs),
                 ( Pair = (Origin-Token), memberchk(Origin, Origins),
                   atom(Token), atom_length(Token, Length), Length >= 24,
                   atom_codes(Token, Codes), forall(member(C, Codes),(C > 32,C < 127)) ))
        -> findall(bearer_token(Origin,Token,[execute,internal_transport]),
                   member(Origin-Token,Pairs),Options)
        ; throw(error(domain_error(peer_inbound_configuration, File),
                      demonstrator_transport_options/1)) )
    ; Options=[] ).
