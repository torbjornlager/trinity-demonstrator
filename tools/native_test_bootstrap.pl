% Select the exact dependency without preloading layers under test.
:- use_module('../demonstrator_startup.pl', []).
:- (catch(demonstrator_startup:configure_native, Error,
          (print_message(error,Error),halt(2))) -> true ; halt(2)).
:- getenv('WP_WASM_SOURCE_DIR',Wasm),
   asserta(user:file_search_path(browser_prolog,Wasm)).
