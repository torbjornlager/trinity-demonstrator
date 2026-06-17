/** <file> debug.pl

Debug bootstrap:

  - loads all modules,
  - opens SWI thread/debug monitors,
  - starts node at `http://localhost:3030/`.
*/

:- load_files(load, [silent(true)]).

:- initialization prolog_ide(debug_monitor).
:- initialization prolog_ide(thread_monitor).

:- initialization node(3030).
