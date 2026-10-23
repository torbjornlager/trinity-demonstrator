:- module(test_layout, [test_asset_root/1, test_asset_file/2]).

/** <module> Test-only demonstrator inputs, independent of runtime layers

WP_ASSET_ROOT has the same meaning as the node's startup environment setting.
No node module is imported: T1/T3 retain their layer-honesty checks. This does
not change client src_uri resolution or the runtime's settings.
*/
:- use_module(library(filesex), [directory_file_path/3]).

test_asset_root(Root) :-
    (getenv('WP_ASSET_ROOT',Configured), Configured \== '' -> Root=Configured
    ;module_property(test_layout,file(File)),file_directory_name(File,Dir),
     directory_file_path(Dir,'../..',Root)).
test_asset_file(Relative,File) :-
    test_asset_root(Root),directory_file_path(Root,Relative,File).
