# Installing resvg-php

## With PIE (recommended)

[PIE](https://github.com/php/pie) resolves `resvg-php/resvg` and installs the
matching prebuilt binary for your PHP version; when no prebuilt asset matches
your platform it falls back to a source build via this repository's `config.m4`
(which drives the Rust build itself):

```sh
pie install resvg-php/resvg
```

## From a release

Download the assets for your PHP version from the releases page. Each release
carries a PIE archive per ABI (`php_resvg-<version>_php8.N-<arch>-linux-glibc-nts.zip`
wrapping `resvg.so`), a bare `resvg-php8.N-linux-<arch>.so` for direct download,
`SHA256SUMS`, and a cosign signature bundle per asset. Verify before installing:

```sh
sha256sum -c SHA256SUMS
cosign verify-blob --bundle resvg-php8.3-linux-x86_64.so.bundle \
    resvg-php8.3-linux-x86_64.so
# on aarch64:
cosign verify-blob --bundle resvg-php8.3-linux-aarch64.so.bundle \
    resvg-php8.3-linux-aarch64.so
# on Alpine / musl:
cosign verify-blob --bundle resvg-php8.3-linux-musl-x86_64.so.bundle \
    resvg-php8.3-linux-musl-x86_64.so
# on macOS (Apple silicon):
cosign verify-blob --bundle resvg-php8.3-darwin-arm64.so.bundle \
    resvg-php8.3-darwin-arm64.so
```

Then point PHP at the extension:

```ini
; php.ini
extension=/opt/resvg-php/resvg-php8.3-linux-x86_64.so
; or /opt/resvg-php/resvg-php8.3-linux-aarch64.so on aarch64
; or /opt/resvg-php/resvg-php8.3-linux-musl-x86_64.so on Alpine (musl)
; or /opt/resvg-php/resvg-php8.3-darwin-arm64.so on macOS (Apple silicon)
; or C:\php\ext\resvg-php8.3-windows-x86_64.dll on Windows
```

The macOS builds are ad-hoc signed Mach-O bundles; `shasum -c SHA256SUMS`
verifies them (macOS ships `shasum` rather than `sha256sum`). PIE resolves
macOS installs from the `-darwin-bsdlibc-` archives automatically. Prebuilt
macOS assets target Apple silicon; on Intel Macs, PIE's source-build fallback
works (Homebrew PHP plus Rust 1.85+).

Windows builds are x64 MSVC, non-thread-safe, and per-PHP-toolset: PHP 8.3's
official Windows builds use VS16 (Visual Studio 2019) and 8.4+/8.5 use VS17
(2022). PIE reads that segment from the target PHP and resolves the matching
archive (`php_resvg-<version>-8.3-nts-vs16-x86_64.zip`, and so on); for a manual
install, take the DLL out of the archive whose compiler segment matches
`php -i`'s `PHP Extension Build`. The extension contains no MSVC runtime beyond
the one PHP itself links (`vcruntime140.dll`).

A `.so` is ABI-bound to its PHP build's thread safety: an NTS extension will not
load under a thread-safe PHP, and vice versa. PIE selects the matching archive
from the `-nts`/`-zts` segment; for a manual install, pick the asset whose
segment matches `php -i | grep 'Thread Safety'`. To build the thread-safe
variant yourself, run `tools/build.sh` against a ZTS `php-config`, and validate
the build with `tools/test-zts.sh`.

Verify:

```sh
php -m | grep resvg
php -r 'echo Resvg\Renderer::version(), PHP_EOL;'
```

The extension is a single self-contained module: on Linux and macOS it depends
on nothing beyond the C library (glibc 2.28 or newer for the glibc builds, any
musl for the Alpine ones; PIE resolves the matching archive automatically), and
on Windows only on the MSVC runtime PHP already loads. It must match your PHP
major.minor ABI exactly (a build for 8.3 refuses to load under 8.4 and vice
versa). The glibc floor is the glibc of the host that built the artifact — 2.28
for current prebuilts — and each release provenance record names the highest
imported symbol version. On minimal Alpine containers where no fonts are
pre-installed, install `ttf-dejavu` (or supply custom fonts via `fontFiles`) so
text is rendered. On minimal Alpine containers where no fonts are
pre-installed, install `ttf-dejavu` (or supply custom fonts via `fontFiles`) so
text is rendered.

## From source

Requirements:

- PHP 8.3, 8.4, or 8.5 with the development headers (`php-dev` / `php8.N-dev`)
- Rust 1.85 or newer, via [rustup](https://rustup.rs) (resvg 0.48.x requires the
  2024 edition)
- `gcc`, `make`, `curl`, `sha256sum`, and `binutils` (`readelf`, `objdump`, `nm`)

```sh
tools/build.sh 8.3        # one of 8.3 | 8.4 | 8.5
```

The build:

1. Downloads the pinned resvg source and verifies its SHA-256.
2. Compiles the Rust bridge into a static archive.
3. Builds the PHP extension with `phpize` and relinks it against that archive.
4. Validates the artifact: export table, dynamic dependencies, hardening flags, and a
   load test.
5. Runs the fidelity gate: the extension's output must be byte-identical to the
   upstream `resvg` binary built from the same source.

The artifact is written to `build/resvg-php<version>.so`. `DEBUG=1 tools/build.sh`
produces an unstripped build for debugging.

### Offline / air-gapped builds

A source build normally resolves Rust dependencies from crates.io at build time.
To build with no network access — or inside a sealed packaging environment —
use the offline source bundle attached to each release
(`resvg-php-<version>-offline.tar.gz`). It packs the repository tree, the
verified resvg source, and every vendored crate; extract it and build with
`OFFLINE=1`:

```sh
tar xzf resvg-php-0.3.0-offline.tar.gz
cd resvg-php-0.3.0-offline
OFFLINE=1 tools/build.sh 8.3
```

`OFFLINE=1` skips the download step, verifies the vendored source against its
recorded SHA-256 marker, and runs cargo with `--frozen`, which fails loudly if
any crate were missing from the bundle. The canonical `phpize` path needs no
special flag: `configure` detects the shipped `native/vendor-crates` directory
and resolves every crate from it, running cargo frozen.

## Fidelity gate

To run the fidelity gate on its own:

```sh
tools/build-oracle.sh                                  # once; builds the oracle CLI
php -n -d extension=build/resvg-php8.3.so tools/gate-render.php
```

The oracle binary is expected at
`vendor-src/resvg-0.48.1/target/release/resvg`, or wherever `RESVG_ORACLE` points.
