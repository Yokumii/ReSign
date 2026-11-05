# Third-party components

ReSign is distributed under the GNU General Public License version 3. See `LICENSE`.

## Vendored source

- **SideSign**, Magesh K and contributors, based on AltSign by Riley Testut and contributors. https://github.com/SideStore/SideSign — GPL-3.0 as declared by upstream. Original source notices are retained. Local changes and the exact revision are documented in `Vendor/SideSign/UPSTREAM.md`.
- **MacAnisette**, copyright (c) 2025 nythepegasus. https://github.com/SideStore/MacAnisette — MIT. ReSign's native AOSKit bridge follows its documented selector usage. The full MIT notice is retained in `Vendor/MacAnisette-LICENSE`.

## Dependencies fetched at build time

- **CodeSignKit**: https://github.com/mahee96/CodeSignKit
- **GSACryptoKit**: https://github.com/mahee96/GSACryptoKit
- **AnisetteKit**: https://github.com/mahee96/AnisetteKit
- **Swift Crypto**: https://github.com/apple/swift-crypto
- **Swift ASN.1**: https://github.com/apple/swift-asn1
- **libdeflate**: https://github.com/SideStore/libdeflate
- **Unicorn** (transitive AnisetteKit binary target): https://github.com/mahee96/unicorn, based on https://github.com/unicorn-engine/unicorn

The exact dependency revisions are recorded in the package manifests and lockfile. Each dependency retains its own license and copyright notices in the resolved source / artifact.

## Device libraries used by local builds

- **libimobiledevice**: https://github.com/libimobiledevice/libimobiledevice — LGPL-2.1.
- **libplist**: https://github.com/libimobiledevice/libplist — LGPL-2.1.
- Homebrew packages may bring additional shared libraries, including libusbmuxd, libimobiledevice-glue and cryptographic libraries. The build script bundles their dynamic dependencies from the local installation; those components remain subject to their individual licenses.

This source repository does not contain prebuilt Homebrew libraries or Apple frameworks. Before distributing a built application, include the notices and corresponding source / relinking materials required by each bundled component.

## Release source and notice collection

The app build copies dependency notices into `ReSign.app/Contents/Resources/Licenses` before signing. Release packaging includes the exact Swift package checkouts, source archives for bundled Homebrew library versions, and the source revision associated with the pinned Unicorn binary. Source URLs, download hashes, Homebrew metadata and build provenance accompany the artifacts. See `docs/RELEASING.md` and `scripts/binary-sources.json`.
