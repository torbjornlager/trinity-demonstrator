/** <file> run.pl

One-command entry point for the PoC node.

Loads the pinned native dependency via `load.pl` and starts the HTTP server on port 3060.
*/


:- [load].

:- node(3060).
