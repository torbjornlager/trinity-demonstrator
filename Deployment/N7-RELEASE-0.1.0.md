# N7 pilot 0.1.0

The local Git tag `n7-pilot-v0.1.0` identifies the owner-only ECLiPSe CLP
7.2.13 pilot. It advertises private ISOTOPE and uses N3 as its only
allowlisted outbound origin. The release includes the catalog and Hub
assets, the N7 seed entry, and the recovery tools.

| Evidence | Identity |
| --- | --- |
| Running N7 engine image | `sha256:67cf6cfbdf4d55a9b900d11222c5a061f67f2139c8d1b8967034992f24a9579e` |
| Saved engine archive SHA-256 | `3e97193310fb12e98296de50486e1821b3fe7b0081d8a3a66c150a0ab949c49b` |
| Recovery manifest SHA-256 | `e654f51bcfdcf46192627a824cf9f0fe3b03fc961974446d03d4709fa8b6e8be` |
| Live N0–N7 smoke result SHA-256 | `09abdbe9c17c154fd5c9a4d5c1076e6eda574414567e5af5de111fac4b795d8f` |
| Trinity conformance revision | `5e4ecdd92a4f7e3eaa80c86a598809ab6be9801c` |

The bridge modules in the source tag match the running image byte-for-byte.
The adapter, edge template, shared catalog page and helper, and Hub page
match the corresponding files in the recovery bundle. The N6 catalog page
in the bundle also contains N6's deployment-specific bootstrap.

A fresh build from the staged release files passed 36 selected HTTP
assertions, including all 17 prompt and interruption cases. The HTTPS
fixture passed owner admission, stateless JSON with request-local source,
answer paging, and a correlated prompt reply. The recovery rehearsal
recreated the edge and adapter and restored the base configuration on
rollback. The [recovery instructions](README.eclipse-n7.md#recovery-bundle)
describe the private bundle and its separately supplied credentials.
