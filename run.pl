/** <file> run.pl

One-command entry point for the PoC node.

Loads the pinned native dependency via `load.pl` (WP_NATIVE_MODE=legacy
explicitly selects the retained native copies) and starts the HTTP server on port 3060.
*/


:- [load].

:- node(localhost:3060).
