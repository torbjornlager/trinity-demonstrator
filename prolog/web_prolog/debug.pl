/** <file> debug.pl

Debug bootstrap:

  - loads all modules,
  - opens SWI thread/debug monitors,
  - starts node at `http://localhost:3030/`.
*/

:- prolog_load_context(directory, ThisDir),
   directory_file_path(ThisDir, '../../load.pl', LoadFile),
   load_files(LoadFile, [silent(true)]).

:- initialization prolog_ide(debug_monitor).
:- initialization prolog_ide(thread_monitor).

:- initialization node(3030).
