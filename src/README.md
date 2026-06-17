# Frozen conformance reference — do not edit

This directory is the trinity-demonstrator's implementation, kept
**byte-frozen** so the LEGACY test tier can run the original system as
the semantic baseline (and so files can be diffed against upstream).

**The real implementation lives in [`prolog/web_prolog/`](../prolog/web_prolog/).**

If you are looking for the layered actor core with its hooks, that is
[`prolog/web_prolog/actors.pl`](../prolog/web_prolog/actors.pl) (module
`actors`) — *not* `src/actor.pl` (module `actor`), which is the
pre-layering original. The same applies to every other file here.

The only deliberate edits ever made under `src/` were the Phase-0
prune of browser-runtime handlers in `node.pl`; everything else is as
forked.
