:- module(domain_origins, [demonstrator_domain_origins/1]).

% All deployed nodes in the demonstrator's domain belong to the same federation.
% Keep public source/spawn and browser-origin admission consistent. This grants
% origin permission, not a different execution profile or a private-node login.
% Peer transports must still authenticate; N7's browser stays owner-only.
demonstrator_domain_origins(Origins) :-
    findall(Origin,
            ( between(0, 7, N),
              format(atom(Origin), 'https://n~d.elfenbenstornet.se', [N]) ),
            Origins).
