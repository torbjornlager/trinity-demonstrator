# Native SWI extraction rehearsal

This local repository is `swi-prolog-node`, extracted from
`trinity-demonstrator`. It has no publishing remote yet. See README.md.

Preserve Web Prolog semantics and package identity (`web_prolog`). No upward
layer imports; opaque pids below distribution. Read
`docs/LAYERED_REAL_NODE_PLAN.md` before structural work. Code relocation and
behavior changes must remain separate commits. Keep the historical
`demonstrator-peer` tag used by T5. Never infer permission to change installed
engines or live n3/n5 from tests in this checkout.

Run native checks with an explicit verified SWIPL and `./tools/test.sh`.
Frontend integration needs explicit asset roots. The original source checkout
and all its files remain intact. The former CLAUDE.md is preserved in Git history.
