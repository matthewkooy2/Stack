# Dependency and implementation provenance

This is an inventory, not a change to Stack's license or a legal clearance of the
whole repository. Original files in this module remain subject to the repository's
existing terms. No AGPL implementation was used as a source for this module.

## Locked npm dependency graph

`package-lock.json` pins the tarball versions and integrity hashes. There are no
development npm dependencies. Install with `npm ci --ignore-scripts` and keep
the upstream notices with redistributed dependencies.

| Package | Locked version | Package license | Role |
| --- | --- | --- | --- |
| `pdfjs-dist` | 6.4.299 | Apache-2.0 | PDF text extraction, official Mozilla distribution |
| `@napi-rs/canvas` | 1.0.10 | MIT | PDF.js optional dependency, required here for Node geometry classes |
| `@napi-rs/canvas-android-arm64` | 1.0.10 | MIT | Optional native binary |
| `@napi-rs/canvas-darwin-arm64` | 1.0.10 | MIT | Optional native binary |
| `@napi-rs/canvas-darwin-x64` | 1.0.10 | MIT | Optional native binary |
| `@napi-rs/canvas-linux-arm-gnueabihf` | 1.0.10 | MIT | Optional native binary |
| `@napi-rs/canvas-linux-arm64-gnu` | 1.0.10 | MIT | Optional native binary |
| `@napi-rs/canvas-linux-arm64-musl` | 1.0.10 | MIT | Optional native binary |
| `@napi-rs/canvas-linux-riscv64-gnu` | 1.0.10 | MIT | Optional native binary |
| `@napi-rs/canvas-linux-x64-gnu` | 1.0.10 | MIT | Optional native binary |
| `@napi-rs/canvas-linux-x64-musl` | 1.0.10 | MIT | Optional native binary |
| `@napi-rs/canvas-win32-arm64-msvc` | 1.0.10 | MIT | Optional native binary |
| `@napi-rs/canvas-win32-x64-msvc` | 1.0.10 | MIT | Optional native binary |

The installed native binary depends on platform. Native canvas packages embed
third-party native components (including Skia); the package MIT declaration is
not a substitute for the embedded components' redistribution notices. This PR
does not vendor or redistribute those binaries. Before building a standalone
release image/bundle, retain and verify upstream native third-party notices for
the exact binary. [Canvas upstream](https://github.com/Brooooooklyn/canvas) and
[Skia license](https://skia.googlesource.com/skia/+/main/LICENSE) are the sources
for that release review.

## Additional assets inside the PDF.js distribution

The extractor uses `legacy/build/pdf.mjs` and its worker. It does not configure
font/CMap/ICC asset paths, render pages, or enable WebAssembly decoding. Nevertheless,
the npm tarball contains additional assets with their own licenses; do not describe
the entire installed directory as solely Apache-2.0:

| Installed notice | Asset/license |
| --- | --- |
| `pdfjs-dist/LICENSE` | PDF.js Apache-2.0 |
| `pdfjs-dist/cmaps/LICENSE` | Adobe CMaps, BSD-style terms |
| `pdfjs-dist/iccs/LICENSE` | ICC data, CC0-1.0 |
| `pdfjs-dist/standard_fonts/LICENSE_FOXIT` | PDFium/Foxit fonts, BSD-style terms |
| `pdfjs-dist/standard_fonts/LICENSE_LIBERATION` | Liberation fonts, GPL v2 with font exceptions; **not a permissive license** |
| `pdfjs-dist/wasm/LICENSE_QCMS` | qcms, MIT |
| `pdfjs-dist/wasm/LICENSE_OPENJPEG` | OpenJPEG, BSD-2-Clause |
| `pdfjs-dist/wasm/LICENSE_JBIG2` | PDFium JBIG2, BSD-style terms |
| `pdfjs-dist/wasm/LICENSE_PDFJS_QCMS` | PDF.js wrapper, Apache-2.0 |
| `pdfjs-dist/wasm/LICENSE_PDFJS_OPENJPEG` | PDF.js wrapper, Apache-2.0 |
| `pdfjs-dist/wasm/LICENSE_PDFJS_JBIG2` | PDF.js wrapper, Apache-2.0 |

Unused Liberation font assets are not needed by this text extraction path. A future
release that requires only permissive shipped assets should explicitly exclude
them in its packaging recipe and test the resulting bundle. Merely disabling font
loading does not change the license of files shipped in a distribution. No release
packaging recipe or repo license change is included here.

## Runtimes and test tooling

Python 3.11+ uses its standard library only (PSF License and bundled notices).
Node.js 22.13+ uses its standard library (Node MIT and its bundled third-party
notices). Neither runtime is vendored. Tests generate fictional PDFs with original
Python code, with no fixture-library dependency. Poppler was used locally to render
synthetic fixtures for visual inspection; it is not a parser runtime dependency or
distributed artifact. CI uses GitHub's checkout/setup-node/setup-python actions
(MIT-licensed tooling); these are not shipped with the parser.

## References actually used

- [PDF.js public API](https://mozilla.github.io/pdf.js/api/)
- [PDF.js document parameters](https://mozilla.github.io/pdf.js/api/draft/module-pdfjsLib.html)
- [PDF.js license](https://github.com/mozilla/pdf.js/blob/master/LICENSE)
- Installed package metadata, lockfile, and bundled license notices above

All category rules, geometry grouping, process supervision, output schema and
synthetic resume content were authored independently for this task. Files explicitly
excluded by the task were not read or used as functional/code references.
