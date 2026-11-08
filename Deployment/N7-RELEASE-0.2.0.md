# N7 full shell 0.2.0 · 8 November 2026

The annotated tag `n7-shell-v0.2.0` records the deployed ECLiPSe CLP 7.2.13
release. Both the [full shell](https://n7.elfenbenstornet.se/n7-shell/)
and [compact pilot](https://n7.elfenbenstornet.se/demonstrator) require
GitHub owner sign-in. The demonstrator catalog and Discovery Hub link to
the full shell. N3 is the only outbound peer on the allowlist.

| Deployed component | Image ID |
| --- | --- |
| N7 engine | `sha256:626fefb394805490ac2c02f9963c4adb8feab9a60e77334c725b6544434da141` |
| N7 OAuth sidecar | `sha256:dcb6ff8dd21bf3058f6a22c6fa385fa5b897a9cd3914c88a2cc2bb0a85f8065d` |
| Shared Caddy edge | `sha256:95a6701892f9230e8b2bca6af205735cedbd6d973b7f5fdbf54d4a01ea6d96cd` |
| N0 Discovery Hub | `sha256:63719c470f6e3cb6127eaecc16d7506c1880e4b6d0d1c55554265d08f89b9ee7` |

The static shell was built from `936d934a9fd1786ecebfc629dfeb782f3244da13`.
Its asset manifest SHA-256 is
`12cb6b5ad4a93ed8ff8a79108b7bd8cf7bf5a70e3c899e8c4741bfdddace00a2`.

The following private evidence paths are relative to the primary
demonstrator checkout.

| Evidence file | SHA-256 |
| --- | --- |
| `.trinity/n7-recovery-full-2026-11-08/manifest.json` | `b8ac8f606113907c208be4beed0f63ff221786b6fd9f01343f47237607afe302` |
| `.trinity/n7-recovery-full-2026-11-08/engine.tar` | `ad16ee3f965e1de49c8b8b1fd0eb8b44f4a9b14630c8d62acd4465e09186ac92` |
| `.trinity/trinity-live-smoke-full-2026-11-08/live-smoke.json` | `ba55948a55911ebf2f072ee7fcc3187da3a7cccde3fcfab800504546300ab0ec` |

The live smoke report records all 18 deployed container image IDs and
passing results for N0–N7. It records owner paging and prompt replies in
both N7 interfaces, plus editor-defined source and peer admission in
the full shell. The recovery rehearsal restored the full release and
rolled back to the compact-only release with its owner gate intact.
See the [recovery instructions](README.eclipse-n7.md#recovery-bundle)
for the separately supplied credentials and restore procedure.

Before tagging, the live container identities, edge configuration, and
published catalog and Hub assets matched the smoke report and recovery
manifest. Both anonymous page visits redirected to GitHub sign-in, and
anonymous shell session metadata and execution returned HTTP 401.
