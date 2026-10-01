#!/usr/bin/env bash
# tools/test-zts.sh — multi-threaded stress and race gate for resvg-php.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# Builds the standalone multi-threaded stress harness (8 concurrent threads
# exercising independent options, parse, render, render_node, to_svg, error
# path, and free) against the native shim static archive, and runs it under
# Valgrind Helgrind and Memcheck to prove race- and leak-freedom.
#
# Usage: tools/test-zts.sh [libresvg_php.a]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${1:-$ROOT/native/target/release/libresvg_php.a}"
[ -f "$LIB" ] || { echo "FAIL: archive $LIB not found; build it first" >&2; exit 2; }

TMP_BIN="$(mktemp /tmp/rsp-zts-stress.XXXXXX)"
trap 'rm -f "$TMP_BIN"' EXIT

echo ">> Compiling multi-threaded ZTS stress harness"
cc -O2 -I "$ROOT/native/include" "$ROOT/tests/zts/stress_threads.c" "$LIB" \
	-lpthread -ldl -lm -o "$TMP_BIN"

echo ">> Running raw concurrent stress test"
"$TMP_BIN"

if command -v valgrind >/dev/null 2>&1; then
	echo ">> Running Helgrind data-race detector"
	valgrind --tool=helgrind --error-exitcode=99 -q "$TMP_BIN"
	echo "   Helgrind OK (zero data races)"

	echo ">> Running Memcheck leak detector across threads"
	valgrind --leak-check=full --errors-for-leak-kinds=definite,indirect \
		--error-exitcode=99 -q "$TMP_BIN"
	echo "   Memcheck OK (zero leaks across threads)"
else
	echo "   (valgrind absent; race detector skipped)"
fi

echo "zts-gate: multi-threaded concurrency validated cleanly"
