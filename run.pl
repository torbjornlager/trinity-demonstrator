/** <file> run.pl

One-command entry point for the PoC node.

Loads all modules via `load.pl` and starts the HTTP server on port 3060.
*/


:- [load].

:- node(localhost:3060).
