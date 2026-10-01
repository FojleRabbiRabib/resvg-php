# Changelog

All notable changes to resvg-php are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
Semantic Versioning.

## [Unreleased]

### Changed

- Linux glibc prebuilts now build on AlmaLinux 8, lowering the required glibc
  from 2.35 to **2.28**. They load on RHEL, Alma, and Rocky 8, Debian 10+,
  Ubuntu 20.04+, and Amazon Linux 2023, where the previous artifacts refused
  to start. The imported-symbol ceiling is a release gate, and each
  provenance record now names the measured floor.
- Alpine (musl) builds run the Alpine toolchain through an explicit docker
  step instead of a job-level container, which GitHub does not support with
  node-based actions on arm64 runners.
- Prebuilt macOS assets target Apple silicon; Intel Macs install through
  PIE's source-build fallback, because upstream publishes no PHP 8.3/8.4
  bottles for the last Intel runner image.

### Added

- Offline / air-gapped source builds: `tools/vendor-offline.sh` vendors every
  Rust crate into `native/vendor-crates` and proves resolution with a frozen
  cargo build; with that directory present, `./configure --enable-resvg` and
  `tools/build.sh` switch cargo to `--frozen` on their own and build with zero
  network access, and each release now carries a self-contained offline source
  bundle (`resvg-php-<version>-offline.tar.gz`) that is extracted and built as
  part of the release workflow itself.

## [0.2.0] - 2026-10-01

### Added

- Linux aarch64 (glibc) as a supported platform on par with x86-64: CI builds
  and gates all three PHP ABIs natively on arm64 runners, and releases carry
  aarch64 PIE archives and bare `.so` assets alongside x86-64.
- Alpine Linux (musl) as a supported platform: a CI job builds and gates the
  extension inside the official `php:8.3-alpine` image, and releases carry
  musl PIE archives and bare `.so` assets for all three PHP ABIs on both
  x86-64 and aarch64. On fontless Alpine containers, install `ttf-dejavu` or
  supply fonts via `fontFiles` so text renders.
- macOS (Apple silicon and Intel) as a supported platform: CI builds and gates
  the extension on macOS runners, and releases carry ad-hoc-signed
  `-darwin-bsdlibc-` PIE archives and bare `.so` assets for all three PHP
  ABIs. The build detects Mach-O and relinks with `ld64` flags and an
  exported-symbols list instead of the ELF version script.
- ZTS (thread-safe) PHP builds are validated, not merely intended-safe: a CI
  job builds and gates the extension under the thread-safe SAPI, asserts the
  module reports thread safety, and runs a multi-threaded stress harness
  (concurrent options, parse, render, node export, writer, error paths, and
  frees across eight threads) under Valgrind Helgrind and Memcheck. Release
  packaging emits the `-zts` thread-safety segment PIE matches.

### Changed

- The Zend ABI check in the build driver reads the module API number from the
  installed headers instead of `php-config --phpapi`, which the official
  Docker PHP images do not implement; source builds inside those images now
  work.
- `phpinfo()` reports thread safety from the build (`enabled (ZTS)` or
  `disabled (NTS)`) instead of a fixed NTS string.
- Release archives use PIE's normalized architecture spelling (`arm64`, never
  `aarch64`) so the installer resolves them on ARM hosts; the host spelling is
  kept as an additional alias. PIE's OS and libc segments (`darwin`,
  `bsdlibc`) are emitted for macOS.

### Fixed

- The ELF dependency gate strips readelf brackets with a POSIX-portable
  pattern, so builds on Alpine (BusyBox awk) validate correctly.
- Checksum tooling falls back to `shasum -a 256` where `sha256sum` is absent,
  and build parallelism uses `sysctl -n hw.ncpu` where `nproc` is absent, so
  the build driver runs on macOS.

## [0.1.1] - 2026-10-01

### Fixed

- PIE prebuilt-binary installs: `download-url-method` moved into the `php-ext`
  composer metadata where the installer reads it, so `pie install
  resvg-php/resvg` uses the matching release archive instead of falling back
  to a source build.
- Release archives are additionally published under the full tag version name
  (`php_resvg-v0.1.1+resvg.0.48.1_...`), which is the name PIE resolves.

## [0.1.0] - 2026-09-30

### Added

- `Resvg\Renderer` with `render()`, `measure()`, and `version()`, backed by a vendored
  resvg 0.48.1 core statically linked into a self-contained `.so`.
- `Resvg\Tree`: parse once, render many. Carries its own font database, so it may
  outlive the renderer that produced it; node-addressed through `hasNode()`,
  `nodeIds()`, and `renderNode()`, and serializable back to SVG through `toSvg()`.
- `Resvg\Exception` (extends `RuntimeException`) for renderer failures, with the
  ABI status codes exposed as class constants (`PARSE_FAILED`, `NO_SUCH_NODE`,
  `TOO_LARGE`, …) and the parser's own detail appended to the message where
  upstream produced one.
- Constructor options: `fontFamily`, `fontSize`, `languages`, `fontFiles`,
  `fontDirs`, `resourcesDir`, `stylesheet`, `dpi`, `width`, `height`,
  `loadSystemFonts`, `confineResources`, `serifFamily`, `sansSerifFamily`,
  `cursiveFamily`, `fantasyFamily`, `monospaceFamily`, `shapeRendering`,
  `textRendering`, `imageRendering`.
- Per-render options: `width`, `height`, `zoom`, `background`, `exportArea`, and
  `output` (stream resource or path) for delivering a render without materializing
  the PNG in PHP memory. Writer options on `toSvg()`: `preserveText`, `idPrefix`,
  `indent`, `attrsIndent`, `coordinatesPrecision`, `transformsPrecision`,
  `useSingleQuote`.
- `Renderer::fonts()` reporting loaded faces as `family => path`, with a
  `E_USER_WARNING` per font file that failed to load.
- `Resvg\Exception::TOO_LARGE` (code 14) for renders whose produced size exceeds
  `resvg.max_render_pixels`.
- Resource ceilings `resvg.max_input_size` and `resvg.max_render_pixels`, enforced
  before the input copy and on the produced render size respectively.
- Opt-in reference confinement via `confineResources` + `resourcesDir`: absolute
  hrefs and any path escaping the root are rejected.
- ELF hardening gates (RELRO, BIND_NOW, non-executable stack, no rpath) and symbol
  isolation exporting only `get_module`.
- PNG fidelity gate: byte-identical output versus the upstream `resvg` CLI, over
  option-set rows, on PHP 8.3, 8.4, and 8.5.
- toSvg fidelity gate: byte-identical output versus the upstream `usvg` CLI over
  the full `WriteOptions` surface and its boundary values.
- Valgrind memory gate over lifecycle churn, error paths, and fork churn.
- `tools/test-memory.sh` driver running the Valgrind suite across both ZendMM
  modes (0 definite, 0 indirect leaks gate) and a dedicated PHP 8.3 CI job.
- `tools/test-examples.sh` runner verifying all `examples/*.php` across all ABIs.
- `tools/benchmark.php` reporting throughput (ops/sec) and real OS memory
  (VmRSS/VmHWM via `/proc/self/status`), with baseline recording and comparison.
- `tools/release-build.sh` assembling PIE-canonical zip archives wrapping `resvg.so`
  and bare `.so` direct-download assets, with `SHA256SUMS` and provenance records.
- `.github/workflows/release.yml` tag workflow assembling releases with syft SBOMs
  and keyless cosign signatures.
- Vendored `tools/gen_stub.php` from php-src and a CI arginfo drift gate
  regenerating `resvg_arginfo.h` from `resvg.stub.php`.
- Canonical PECL `package.xml` manifest and PIE `composer.json` integration.
- Community and support surfaces: `.github/SECURITY.md`, `.github/FUNDING.yml`,
  and GitHub issue templates.

### Changed

- `render()`, `renderFile()`, `Tree::render()`, and `renderNode()` return
  `string|bool`: the PNG string normally, `true` when an `output` sink received it.
- `parseFile()`/`renderFile()`/`measureFile()` resolve `resourcesDir` to the file's
  own canonical directory when the caller set none, mirroring the CLI.
- `confineResources` requires `resourcesDir`; the two are rejected together with a
  `ValueError` when the root is missing.
- `dpi` is validated to 10..4000 and `fontSize` to 1..192, matching the CLI; an
  explicit non-positive `zoom` raises `ValueError` instead of meaning "unset".

### Security

- `resvg.max_render_pixels` is enforced on the size a render actually produces —
  after fit-to resolution — so `zoom`, single-side fits, default-size documents,
  and node exports are all bounded, with the product computed in 64-bit.
- `resvg.max_input_size` is enforced before the document is copied into memory,
  and oversized `*File()` reads report the ceiling rather than a generic failure.
- Node-export rendering paints only the requested node, matching `--export-id`,
  so sibling content outside the exported node is not composited in.
