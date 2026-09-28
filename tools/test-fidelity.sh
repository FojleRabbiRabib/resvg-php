#!/usr/bin/env bash
# tools/test-fidelity.sh — run both fidelity gates against the upstream CLIs. The
# resvg binary is the PNG gate's oracle, the usvg binary the toSvg gate's; both
# are built from the same pinned, hash-verified source the extension renders
# with, so the comparisons are like-for-like.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# Usage: tools/test-fidelity.sh <path-to-resvg.so>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SO="${1:-}"
[ -n "$SO" ] || { echo "FAIL: usage: tools/test-fidelity.sh <resvg.so>" >&2; exit 2; }
[ -f "$SO" ] || { echo "FAIL: $SO not found" >&2; exit 2; }

RESVG_VERSION="${RESVG_VERSION:-0.48.1}"
ORACLE="$ROOT/vendor-src/resvg-$RESVG_VERSION/target/release/resvg"
USVG_ORACLE="$ROOT/vendor-src/resvg-$RESVG_VERSION/target/release/usvg"
if [ ! -x "$ORACLE" ] || [ ! -x "$USVG_ORACLE" ]; then
	"$ROOT/tools/build-oracle.sh"
fi

PHP_BIN="${PHP_BIN:-php}"
if [ -z "${PHP_VERSION:-}" ] && [[ "$SO" =~ php(8\.[3-5])(-debug)?\.so$ ]]; then
	PHP_VERSION="${BASH_REMATCH[1]}"
fi
if [ -n "${PHP_VERSION:-}" ] && command -v "php$PHP_VERSION" >/dev/null 2>&1; then
	PHP_BIN="php$PHP_VERSION"
fi

RESVG_ORACLE="$ORACLE" "$PHP_BIN" -n -d "extension=$SO" "$ROOT/tools/gate-render.php"
USVG_ORACLE="$USVG_ORACLE" "$PHP_BIN" -n -d "extension=$SO" "$ROOT/tools/gate-tosvg.php"
