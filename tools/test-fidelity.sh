#!/usr/bin/env bash
# tools/test-fidelity.sh — run the render-fidelity gate against the upstream resvg
# CLI. The oracle is built from the same pinned, hash-verified source the extension
# renders with, so the comparison is like-for-like.
#
# Usage: tools/test-fidelity.sh <path-to-resvg.so>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SO="${1:-}"
[ -n "$SO" ] || { echo "FAIL: usage: tools/test-fidelity.sh <resvg.so>" >&2; exit 2; }
[ -f "$SO" ] || { echo "FAIL: $SO not found" >&2; exit 2; }

RESVG_VERSION="${RESVG_VERSION:-0.48.1}"
ORACLE="$ROOT/vendor-src/resvg-$RESVG_VERSION/target/release/resvg"
if [ ! -x "$ORACLE" ]; then
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
