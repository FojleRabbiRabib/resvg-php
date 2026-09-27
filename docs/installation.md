# Installing resvg-php

## From a release

Download the archive for your PHP version from the releases page, extract it, and
point PHP at the extension:

```ini
; php.ini
extension=/opt/resvg-php/resvg-php8.3.so
```

Verify:

```sh
php -m | grep resvg
php -r 'echo Resvg\Renderer::version(), PHP_EOL;'
```

The extension is a single self-contained `.so` — it has no dependency beyond glibc,
and it must match your PHP major.minor ABI exactly (a build for 8.3 refuses to load
under 8.4 and vice versa).

## From source

Requirements:

- PHP 8.3, 8.4, or 8.5 with the development headers (`php-dev` / `php8.N-dev`)
- Rust 1.85 or newer, via [rustup](https://rustup.rs) (the `c-api` requires the 2024
  edition)
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
