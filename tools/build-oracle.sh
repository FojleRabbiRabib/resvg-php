#!/usr/bin/env bash
# tools/build-oracle.sh — build the upstream resvg AND usvg CLIs from the same
# pinned, hash-verified source the extension renders with. The resvg binary is the
# PNG fidelity gate's oracle; the usvg binary is the toSvg gate's oracle.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# tools/fetch-resvg.sh is the single fetch+verify path for both.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null 2>&1 || {
	echo "FAIL: cargo not found; install Rust >= 1.85 (resvg MSRV)" >&2
	exit 1
}

SRC="$("$ROOT/tools/fetch-resvg.sh")"

cargo build --release --locked --manifest-path "$SRC/Cargo.toml" -p resvg --bin resvg
cargo build --release --locked --manifest-path "$SRC/Cargo.toml" -p usvg --bin usvg
echo "oracle: $SRC/target/release/resvg"
echo "oracle: $SRC/target/release/usvg"

