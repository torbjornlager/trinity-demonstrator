:- module(domain_origins, [demonstrator_domain_origins/1, demonstrator_transport_options/1]).
:- use_module(library(readutil)).

% All deployed nodes in the demonstrator's domain belong to the same federation.
% Keep public source/spawn and browser-origin admission consistent. This grants
% origin permission, not a different execution profile or a private-node login.
% Peer transports must still authenticate; N7's browser stays owner-only.
demonstrator_domain_origins(Origins) :-
    findall(Origin,
            ( between(0, 7, N),
              format(atom(Origin), 'https://n~d.elfenbenstornet.se', [N]) ),
            Origins).

% The owner already mounts this file and sets the environment variable. Read
% it once at startup so distribution can send the existing peer credentials.
% Configuration errors name the file, never a token or its parsed contents.
demonstrator_transport_options(Options) :-
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
