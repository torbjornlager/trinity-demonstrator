% Discovery hub seed for COEXIST mode: the n0 hub runs alongside the
% existing demonstrator stack, joined to its `deployment_wp_net` network
% (see compose.hub-attach.yaml). n0 itself is added automatically and
% self-probes localhost, so it is not listed here.
%
% Every peer is DISPLAYED at its public URL but PROBED over the container
% network at its in-stack service name and port — fast, no NAT hairpin,
% and nothing extra exposed publicly. (Demonstrator service names/ports:
% wp_n1:3051, wp_n2:3052, wp_n3:3053, wp_n4:3055, wp_n5:3060.)

seed_node(n1, 'https://n1.elfenbenstornet.se',
    "The conservative stateless node.  Relational querying and stateless \c
     Prolog execution over the /call API.",
    "Family predicates plus human(plato), human(aristotle), and \c
     deployment_node(n1).",
    "").
seed_probe_url(n1, 'http://wp_n1:3051').

seed_node(n2, 'https://n2.elfenbenstornet.se',
    "The semi-stateful HTTP node.  Adds toplevel sessions, private \c
     session databases, incremental loading, and an rpc/2-3 demo.",
    "Common family predicates plus mortal/1, ancestor/2, descendant/2, \c
     human(socrates), and a distributed human/1.",
    "").
seed_probe_url(n2, 'http://wp_n2:3052').

seed_node(n3, 'https://n3.elfenbenstornet.se',
    "The fully stateful node.  Adds /ws, direct actor messaging, \c
     node-resident services, and the statechart demonstrator.",
    "Common base + actor-common layer + the n3 overlay, with registered \c
     counter / pubsub_service services.",
    "").
seed_probe_url(n3, 'http://wp_n3:3053').

seed_node(n4, 'https://n4.elfenbenstornet.se',
    "A second public ACTOR node for cross-node actor and statechart \c
     demonstrations.  Pair it with n3 for distributed messaging.",
    "Common base + the same actor-common layer as n3, plus an n4 overlay \c
     providing human(plato) / human(aristotle).",
    "").
seed_probe_url(n4, 'http://wp_n4:3055').

seed_node(n5, 'https://n5.elfenbenstornet.se',
    "The layered web-prolog production node, behind GitHub SSO.  Private \c
     (actor) profile; signed-in users get the registered capability tier.",
    "The default node shared database (family / human facts) plus \c
     whatever the owner loads.",
    "Behind SSO — sign in to use it.").
seed_probe_url(n5, 'http://wp_n5:3060').
