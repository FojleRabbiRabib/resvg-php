#!/usr/bin/env bash
# tools/vendor-offline.sh — build a self-contained offline source bundle.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# Vendoring has two consumers:
#   * local/CI offline builds: this script creates native/vendor-crates/ plus
#     native/.cargo/config.toml, after which `OFFLINE=1 tools/build.sh` needs
#     no network;
#   * air-gapped source builds: `--tarball` packs the repository, the
#     hash-verified resvg source, and the vendored crates into one archive
#     that builds out of the box with OFFLINE=1.
#
# Usage: tools/vendor-offline.sh [--tarball]
# Env: RESVG_VERSION, RESVG_SHA256 (forwarded to tools/fetch-resvg.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACK_TARBALL=0
[ "${1:-}" = "--tarball" ] && PACK_TARBALL=1

export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null 2>&1 || {
	echo "FAIL: cargo not found; install Rust >= 1.85 (resvg MSRV)" >&2
	exit 1
}

echo ">> Fetching the pinned resvg source"
"$ROOT/tools/fetch-resvg.sh" >/dev/null

echo ">> Vendoring crates.io dependencies into native/vendor-crates"
(cd "$ROOT/native" && cargo vendor --locked vendor-crates >/dev/null)

mkdir -p "$ROOT/native/.cargo"
cat > "$ROOT/native/.cargo/config.toml" <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor-crates"
EOF

echo ">> Proving the vendor set: cargo build --frozen"
(cd "$ROOT/native" && cargo build --frozen >/dev/null)
echo "   offline shim build OK"

if [ "$PACK_TARBALL" = "1" ]; then
	EXT_VERSION="$(awk -F'"' '/#define PHP_RESVG_VERSION/ {print $2}' "$ROOT/php_resvg.h")"
	[ -n "$EXT_VERSION" ] || { echo "FAIL: could not determine PHP_RESVG_VERSION" >&2; exit 1; }
	OUT="${OUT_DIR:-$ROOT/build}/resvg-php-${EXT_VERSION}-offline.tar.gz"
	STAGE="$(mktemp -d)"
	trap 'rm -rf "$STAGE"' EXIT
	mkdir -p "$STAGE/resvg-php-${EXT_VERSION}-offline"

	echo ">> Packing offline source bundle: $(basename "$OUT")"
	# Repository files (tracked tree), the verified upstream source, and the
	# vendored crates — the three inputs an offline build consumes.
	# safe.directory covers containerized runs, where the mounted work tree is
	# owned by a different uid and git would otherwise refuse it (this path
	# runs on the host in the release offline-bundle job, so only local
	# package builds hit that).
	git -c safe.directory="$ROOT" -C "$ROOT" archive HEAD | tar -x -C "$STAGE/resvg-php-${EXT_VERSION}-offline"
	# vendor-src/ is gitignored, so it is not in the archive; create its parent
	# before copying the verified upstream tree into place.
	mkdir -p "$STAGE/resvg-php-${EXT_VERSION}-offline/vendor-src"
	cp -a "$ROOT/vendor-src/resvg-0.48.1" "$STAGE/resvg-php-${EXT_VERSION}-offline/vendor-src/resvg-0.48.1"
	rm -rf "$STAGE/resvg-php-${EXT_VERSION}-offline/vendor-src/resvg-0.48.1/target"
	cp -a "$ROOT/native/vendor-crates" "$STAGE/resvg-php-${EXT_VERSION}-offline/native/vendor-crates"
	# native/.cargo/ is gitignored, so `git archive` never carries the redirect
	# that points cargo at the vendored crates; without it a canonical phpize
	# build inside the extracted bundle dies with "no matching package named
	# <crate> found". The extraction proof above exercises build.sh, which
	# applies --frozen without needing the config, which is why this gap
	# survived that check.
	mkdir -p "$STAGE/resvg-php-${EXT_VERSION}-offline/native/.cargo"
	cp -a "$ROOT/native/.cargo/config.toml" \
		"$STAGE/resvg-php-${EXT_VERSION}-offline/native/.cargo/config.toml"

	tar -czf "$OUT" -C "$STAGE" "resvg-php-${EXT_VERSION}-offline"
	echo "   packed: $OUT ($(du -h "$OUT" | cut -f1))"
fi

echo "vendor-offline: native/vendor-crates and native/.cargo/config.toml are ready"
