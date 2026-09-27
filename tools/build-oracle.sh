#!/usr/bin/env bash
# tools/build-oracle.sh — build the upstream resvg CLI from the same pinned,
# hash-verified source the extension renders with. The resulting binary is the
# fidelity gate's oracle.
set -euo pipefail

RESVG_VERSION="${RESVG_VERSION:-0.48.1}"
RESVG_SHA256="${RESVG_SHA256:-40dafea6b4b9d01e9d28b6d49f1e912daf3e9055676ad9179a5a2db6e7386945}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="$ROOT/vendor-src"
SRC="$V/resvg-$RESVG_VERSION"
TARBALL="$V/resvg-v$RESVG_VERSION.tar.gz"

export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null 2>&1 || {
	echo "FAIL: cargo not found; install Rust >= 1.85 (resvg $RESVG_VERSION MSRV)" >&2
	exit 1
}

mkdir -p "$V"
[ -f "$TARBALL" ] || curl -fsSL -o "$TARBALL" \
	"https://codeload.github.com/linebender/resvg/tar.gz/refs/tags/v$RESVG_VERSION"
actual_sha="$(sha256sum "$TARBALL" | awk '{print $1}')"
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

cargo build --release --manifest-path "$SRC/Cargo.toml" -p resvg --bin resvg
echo "oracle: $SRC/target/release/resvg"
