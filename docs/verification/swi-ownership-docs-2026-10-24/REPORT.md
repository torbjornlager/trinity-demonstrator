# Native SWI ownership documentation — 24 October 2026

Documentation-only consumer cleanup. The demonstrator README now focuses on
assets, browser runtimes, shared language documentation and consumer integration.
It links to the native repository for standalone use. The retained runtime guide
marks its native sources as compatibility copies; the root README's four transport
paragraphs were transferred there verbatim to preserve their useful detail.

The new maintenance guide defines ownership and the full-SHA pin-update workflow,
including exact-HEAD validation, native tests, pinned integration, generated
payloads, legacy comparison and the need for explicit compatibility mirroring.
Native fixes begin in `swi-prolog-node`. Its pinned checkout and HEAD are not
changed by this consumer-documentation batch. Updating the pin does not update
retained copies, installed engines or running nodes.

The extraction map records these rules and the pause in deployment packaging.
Historical records and all implementation files are retained. No packaging code
was written during the preceding borrowed-computer inspection.

Verification:

- All 103 relative Markdown link targets across the four edited/new guide files
  exist. The new section anchors were checked against their headings. Remote
  GitHub links identify the established repositories; private-repository web
  access was not provisioned or claimed tested.
- All 272 pre-edit non-documentation code/configuration/asset file hashes remain
  identical, including workflow, startup, pin and test files.
- Native checkout HEAD and working status remain unchanged.
- Installed SWI/Trealla executable targets and hashes still match the preceding
  pinned-CI preservation record.
- n3/n5 process IDs, start times and commands match the pre-edit snapshot.
- `git diff --check` passes; all changed or added files are Markdown documents.

No runtime suites were rerun for this documentation-only change. No engine,
configuration, credential, repository access, launcher or live node was changed.
