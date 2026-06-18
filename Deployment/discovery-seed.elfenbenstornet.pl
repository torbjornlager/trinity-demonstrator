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

% The public demonstrator nodes n1–n4 live in a separate stack and are
% probed over their public URLs. If this stack runs on the same host and
% public hairpinning is unreliable, switch these to internal
% seed_probe_url/2 targets as in discovery-seed.coexist.pl.
seed_node(n1, 'https://n1.elfenbenstornet.se',
    "The conservative stateless node.  Relational querying and stateless \c
     Prolog execution over the /call API.",
    "Family predicates from the common deployment layer, plus \c
     human(plato), human(aristotle), and deployment_node(n1).",
    "").

seed_node(n2, 'https://n2.elfenbenstornet.se',
    "The semi-stateful HTTP node.  Adds toplevel sessions, private \c
     session databases, incremental loading, and an rpc/2-3 demo.",
    "Common family predicates plus mortal/1, ancestor/2, descendant/2, \c
     human(socrates), and a distributed human/1.",
    "").

seed_node(n3, 'https://n3.elfenbenstornet.se',
    "The fully stateful node.  Adds /ws, direct actor messaging, \c
     node-resident services, and the statechart demonstrator.",
    "Common base + actor-common layer + the n3 overlay, with registered \c
     counter / pubsub_service services.",
    "").

seed_node(n4, 'https://n4.elfenbenstornet.se',
    "A second public ACTOR node for cross-node actor and statechart \c
     demonstrations.  Pair it with n3 for distributed messaging.",
    "Common base + the same actor-common layer as n3, plus an n4 overlay \c
     providing human(plato) / human(aristotle).",
    "").
