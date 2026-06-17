:- module(node_version,
   [ node_version_info/1          % -Dict
   ]).

/** <module> Node build/version information

Best-effort identity of the running build, for the `/version` endpoint
and for operators correlating logs with a release.  Every component
degrades to the atom `unknown` rather than failing, so `/version` is
always answerable.
*/

:- use_module(library(option)).
:- use_module(remote_protocol, [protocol_version/1]).

%!  node_version_info(-Dict) is det.
%
%   A JSON-ready dict with the web_prolog pack version, the SWI-Prolog
%   version, the cross-node wire protocol version, and (in a source
%   checkout) the git revision.
node_version_info(json{
        web_prolog: WP,
        swipl: SWI,
        protocol: Protocol,
        git: Git
    }) :-
    web_prolog_version(WP),
    swipl_version(SWI),
    protocol_version(Protocol),
    git_revision(Git).

%!  web_prolog_version(-Version) is det.
%
%   Prefer the installed pack's registered version; fall back to
%   reading `pack.pl` relative to this module (source checkout); else
%   `unknown`.
web_prolog_version(Version) :-
    (   catch(pack_property(web_prolog, version(V)), _, fail)
    ->  atom_string(V, Version)
    ;   pack_file_version(V)
    ->  atom_string(V, Version)
    ;   Version = "unknown"
    ).

pack_file_version(Version) :-
    module_property(node_version, file(ThisFile)),
    file_directory_name(ThisFile, Dir),               % prolog/web_prolog
    directory_file_path(Dir, '../../pack.pl', PackFile0),
    absolute_file_name(PackFile0, PackFile),
    exists_file(PackFile),
    setup_call_cleanup(
        open(PackFile, read, Stream),
        read_pack_version(Stream, Version),
        close(Stream)).

read_pack_version(Stream, Version) :-
    read_term(Stream, Term, []),
    (   Term == end_of_file
    ->  fail
    ;   Term = version(Version)
    ->  true
    ;   read_pack_version(Stream, Version)
    ).

%!  swipl_version(-Version) is det.
swipl_version(Version) :-
    (   current_prolog_flag(version_data, swi(Ma, Mi, Pa, _))
    ->  format(string(Version), "~w.~w.~w", [Ma, Mi, Pa])
    ;   current_prolog_flag(version, N)
    ->  atom_number(A, N), atom_string(A, Version)
    ;   Version = "unknown"
    ).

%!  git_revision(-Rev) is det.
%
%   Read the git HEAD relative to the repository root, resolving a
%   symbolic ref to its commit.  Absent in an installed pack (no
%   `.git`), where it is reported as `unknown` — the pack version is
%   the meaningful identifier there.
git_revision(Rev) :-
    (   git_head_sha(SHA)
    ->  Rev = SHA
    ;   Rev = "unknown"
    ).

git_head_sha(SHA) :-
    module_property(node_version, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../../.git', GitDir0),
    absolute_file_name(GitDir0, GitDir),
    exists_directory(GitDir),
    directory_file_path(GitDir, 'HEAD', HeadFile),
    exists_file(HeadFile),
    read_file_to_string(HeadFile, Head0, []),
    split_string(Head0, "", " \t\n", [Head]),
    (   string_concat("ref: ", Ref, Head)
    ->  directory_file_path(GitDir, Ref, RefFile),
        exists_file(RefFile),
        read_file_to_string(RefFile, SHA0, []),
        split_string(SHA0, "", " \t\n", [SHA])
    ;   SHA = Head
    ).

:- use_module(library(readutil), [read_file_to_string/3]).
