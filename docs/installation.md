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
```

Then point PHP at the extension:

```ini
; php.ini
extension=/opt/resvg-php/resvg-php8.3-linux-x86_64.so
```

Verify:

```sh
php -m | grep resvg
php -r 'echo Resvg\Renderer::version(), PHP_EOL;'
```

The extension is a single self-contained `.so` — it has no dependency beyond glibc
(the floor is the build host's glibc; the release provenance records the highest
imported symbol version), and it must match your PHP major.minor ABI exactly (a
build for 8.3 refuses to load under 8.4 and vice versa).

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

## Fidelity gate

To run the fidelity gate on its own:

```sh
tools/build-oracle.sh                                  # once; builds the oracle CLI
php -n -d extension=build/resvg-php8.3.so tools/gate-render.php
```

The oracle binary is expected at
`vendor-src/resvg-0.48.1/target/release/resvg`, or wherever `RESVG_ORACLE` points.
