:- module(node_assets, [
    node_asset_file/2,
    node_wasm_source_directory/1
]).

/** <module> Operator-configured demonstrator asset locations

These process-wide settings locate files without changing their public URLs.
An empty root preserves the source-checkout layout. Explicit roots do not fall
back to another checkout when a file is missing. This module stays at the node
layer; actor/source loading and lower-layer example helpers are independent.
*/

:- use_module(library(settings)).
:- use_module(library(filesex), [directory_file_path/3]).

:- setting(root, atom, env('WP_ASSET_ROOT', ''),
           'Demonstrator root containing web/, img/ and examples/; empty uses the current checkout layout').
:- setting(wasm_directory, atom, env('WP_WASM_SOURCE_DIR', ''),
           'Directory of allowlisted browser Prolog sources; empty follows the asset root or current runtime layout').

%!  node_asset_file(+RelativePath, -File) is det.
%
%   RelativePath is supplied by trusted route code. Request paths still pass
%   through node:safe_relative_file/3 in the existing prefix handlers.
node_asset_file(RelativePath, File) :-
    asset_root(Root),
    directory_file_path(Root, RelativePath, File).

asset_root(Root) :-
    setting(root, Configured),
    (   Configured == ''
    ->  module_directory(Dir),
        directory_file_path(Dir, '../..', Root)
    ;   Root = Configured
    ).

%!  node_wasm_source_directory(-Directory) is nondet.
%
%   Only the unconfigured legacy layout retains its old CWD fallback.
node_wasm_source_directory(Dir) :-
    setting(wasm_directory, Explicit),
    setting(root, Root),
    (   Explicit \== ''
    ->  Dir = Explicit
    ;   Root \== ''
    ->  directory_file_path(Root, 'prolog/web_prolog/wasm', Dir)
    ;   legacy_wasm_directory(Dir)
    ).

legacy_wasm_directory(Dir) :-
    module_directory(RuntimeDir),
    directory_file_path(RuntimeDir, wasm, Dir).
legacy_wasm_directory(Dir) :-
    working_directory(Cwd, Cwd),
    directory_file_path(Cwd, 'prolog/web_prolog/wasm', Dir).

module_directory(Dir) :-
    module_property(node_assets, file(File)),
    file_directory_name(File, Dir).
