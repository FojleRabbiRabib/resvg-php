#!/usr/bin/env bash
# tools/test-examples.sh — run every example against a built extension.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# Each examples/*.php must execute cleanly (exit 0) under the PHP ABI matching
# the given extension. A new example is picked up automatically; there is no
# hand-maintained list to forget to update.
#
# Usage: tools/test-examples.sh <resvg.so>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SO="${1:-}"
[ -n "$SO" ] || { echo "FAIL: usage: tools/test-examples.sh <resvg.so>" >&2; exit 2; }
[ -f "$SO" ] || { echo "FAIL: $SO not found" >&2; exit 2; }

PHP_BIN="${PHP_BIN:-php}"
if [ -z "${PHP_VERSION:-}" ] && [[ "$SO" =~ php(8\.[3-5])(-debug)?\.(so|dll)$ ]]; then
	PHP_VERSION="${BASH_REMATCH[1]}"
fi
if [ -n "${PHP_VERSION:-}" ] && command -v "php$PHP_VERSION" >/dev/null 2>&1; then
	PHP_BIN="php$PHP_VERSION"
fi

examples=()
while IFS= read -r f; do
	[ -n "$f" ] && examples+=("$f")
done < <(find "$ROOT/examples" -maxdepth 1 -type f -name '*.php' | sort)
[ "${#examples[@]}" -gt 0 ] || { echo "FAIL: no examples under examples/" >&2; exit 2; }

failures=0
for example in "${examples[@]}"; do
	name="$(basename "$example")"
	if "$PHP_BIN" -n -d "extension=$SO" "$example" >/tmp/rsp-example-out.log 2>&1; then
		echo "PASS  $name"
	else
		echo "FAIL  $name"
		cat /tmp/rsp-example-out.log >&2
		failures=$((failures + 1))
	fi
done

[ "$failures" -eq 0 ] || { echo "FAIL: $failures example(s) failed" >&2; exit 1; }
echo "examples gate: ${#examples[@]} example(s) on $PHP_BIN, all clean"
