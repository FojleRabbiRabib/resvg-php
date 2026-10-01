#!/usr/bin/env bash
# tools/fetch-resvg.sh — the single fetch+verify path for the pinned resvg source.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# Downloads the pinned tarball if absent, verifies its SHA-256, and extracts it
# under vendor-src/. Both tools/build.sh and tools/build-oracle.sh call this, so
# the extension and the oracle CLIs are always built from the identical verified
# tree. On success the verified source directory is printed to stdout; every
# diagnostic goes to stderr.
#
# Env: RESVG_VERSION, RESVG_SHA256.
set -euo pipefail

RESVG_VERSION="${RESVG_VERSION:-0.48.1}"
RESVG_SHA256="${RESVG_SHA256:-40dafea6b4b9d01e9d28b6d49f1e912daf3e9055676ad9179a5a2db6e7386945}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="$ROOT/vendor-src"
SRC="$V/resvg-$RESVG_VERSION"
TARBALL="$V/resvg-v$RESVG_VERSION.tar.gz"

# SHA-256 calculator: `sha256sum` on Linux, `shasum -a 256` on macOS / BSD.
calc_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		echo "FAIL: neither sha256sum nor shasum found" >&2
		exit 1
	fi
}

mkdir -p "$V"
[ -f "$TARBALL" ] || curl -fsSL -o "$TARBALL" \
	"https://codeload.github.com/linebender/resvg/tar.gz/refs/tags/v$RESVG_VERSION"
actual_sha="$(calc_sha256 "$TARBALL")"
[ "$actual_sha" = "$RESVG_SHA256" ] || {
	echo "FAIL: resvg SHA256 mismatch (expected $RESVG_SHA256, got $actual_sha)" >&2
	exit 1
}
if [ ! -d "$SRC/crates/resvg" ]; then
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar xzf "$TARBALL" -C "$SRC" --strip-components=1
fi
printf '%s\n' "$RESVG_SHA256" > "$SRC/.verified-source-sha256"

printf '%s\n' "$SRC"
