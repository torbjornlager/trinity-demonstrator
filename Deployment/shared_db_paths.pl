:- module(shared_db_paths, [
    common_shared_db_path/1,
    node_overlay_shared_db_path/2
]).

:- use_module(library(filesex), [directory_file_path/3]).

common_shared_db_path(SharedDBPath) :-
    source_file(common_shared_db_path(_), SourceFile),
    file_directory_name(SourceFile, Dir),
    directory_file_path(Dir, 'shared_db_common.pl', RelativePath),
    absolute_file_name(RelativePath, SharedDBPath).

node_overlay_shared_db_path(NodeName, SharedDBPath) :-
    source_file(node_overlay_shared_db_path(_, _), SourceFile),
    file_directory_name(SourceFile, Dir),
    atom_concat('shared_db_', NodeName, BaseName0),
    atom_concat(BaseName0, '.pl', BaseName),
    directory_file_path(Dir, BaseName, RelativePath),
    absolute_file_name(RelativePath, SharedDBPath).
