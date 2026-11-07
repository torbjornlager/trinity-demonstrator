% Local preview registry; public N0's seed and network stay unchanged.
seed_node(n1, 'https://n1.elfenbenstornet.se', "ISOBASE node.", "Common relational examples.", "").
seed_implementation(n1, 'SWI-Prolog').
seed_node(n2, 'https://n2.elfenbenstornet.se', "ISOTOPE node.", "Shared relational examples and sessions.", "").
seed_implementation(n2, 'SWI-Prolog').
seed_node(n3, 'https://n3.elfenbenstornet.se', "ACTOR node.", "Shared actor examples.", "").
seed_implementation(n3, 'SWI-Prolog').
seed_node(n4, 'https://n4.elfenbenstornet.se', "ACTOR node.", "Shared actor examples.", "").
seed_implementation(n4, 'SWI-Prolog').
seed_node(n5, 'https://n5.elfenbenstornet.se', "ACTOR node.", "Owner-curated actor examples and Linda.", "").
seed_implementation(n5, 'Trealla Prolog').
seed_node(n6, 'http://localhost:3057',
    "Local ISOBASE preview.",
    "Family relations, prices, human/1 and deployment_node(n6).",
    "Local preview; no actor or session API.").
seed_implementation(n6, 'GNU Prolog').
seed_probe_url(n6, 'http://wp_n6:3060').
