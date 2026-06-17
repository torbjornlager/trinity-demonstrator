% Discovery hub seed for the elfenbenstornet.se deployment.
%
% Loaded by the n0 hub via WP_DISCOVERY_SEED_FILE (see
% compose.elfenbenstornet.yaml). n0 — the hub itself — is added
% automatically and self-probes localhost, so it is not listed here.

% n5 is co-located with the hub in the same compose, so it is PROBED
% over the container network (http://n5:3060) while still DISPLAYED at
% its public URL. This is the seed_probe_url/2 decoupling: a node behind
% a reverse proxy cannot in general be reached at its own public name
% from inside the same host (NAT hairpin), and n5 is additionally behind
% SSO — so the hub reaches it directly instead.
seed_node(n5, 'https://n5.elfenbenstornet.se',
    "The layered web-prolog production node, behind GitHub SSO. \c
     Private (actor) profile; signed-in users get the registered \c
     capability tier.",
    "The default node shared database (family / human facts) plus \c
     whatever the owner loads.",
    "Behind SSO — sign in to use it.").
seed_probe_url(n5, 'http://n5:3060').

% The public demonstrator nodes n1–n4 live in a separate stack. To show
% them in this directory too, uncomment them. They are probed over the
% public internet, so the hub's host must be able to reach those URLs
% (NAT hairpin if they sit on the same server); otherwise give each an
% internal seed_probe_url/2 the way n5 has one.
%
% seed_node(n1, 'https://n1.elfenbenstornet.se',
%     "The conservative stateless node (ISOBASE).", "Family + human facts.", "").
% seed_node(n2, 'https://n2.elfenbenstornet.se',
%     "The semi-stateful HTTP node (ISOTOPE).", "Family facts + rpc demo.", "").
% seed_node(n3, 'https://n3.elfenbenstornet.se',
%     "The fully stateful node (ACTOR).", "Actor-common layer + services.", "").
% seed_node(n4, 'https://n4.elfenbenstornet.se',
%     "A second public ACTOR node.", "Same actor-common layer as n3.", "").
