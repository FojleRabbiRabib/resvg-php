#!/usr/bin/env bash
# tools/test-memory.sh — Valgrind memory gate across the lifecycle churn suite.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# Runs every tests/memory/*.php case under Valgrind in both ZendMM modes
# (default allocator, and USE_ZEND_ALLOC=0 so leaks are not masked). The gate
# is zero definite leaks, zero indirect leaks, and zero invalid frees.
#
# Usage: tools/test-memory.sh <resvg.so>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SO="${1:-}"
[ -n "$SO" ] || { echo "FAIL: usage: tools/test-memory.sh <resvg.so>" >&2; exit 2; }
[ -f "$SO" ] || { echo "FAIL: $SO not found" >&2; exit 2; }

command -v valgrind >/dev/null 2>&1 || {
	echo "FAIL: valgrind not found; install valgrind" >&2
	exit 2
}

PHP_BIN="${PHP_BIN:-php}"
if [ -z "${PHP_VERSION:-}" ] && [[ "$SO" =~ php(8\.[3-5])(-debug)?\.so$ ]]; then
	PHP_VERSION="${BASH_REMATCH[1]}"
fi
if [ -n "${PHP_VERSION:-}" ] && command -v "php$PHP_VERSION" >/dev/null 2>&1; then
	PHP_BIN="php$PHP_VERSION"
fi
echo "memory gate: $PHP_BIN + $SO"

VALGRIND=(
	valgrind
	--error-exitcode=99
	--leak-check=full
	"--show-leak-kinds=definite,indirect,possible"
	"--errors-for-leak-kinds=definite,indirect"
	-q
)

cases=()
while IFS= read -r f; do
	[ -n "$f" ] && cases+=("$f")
done < <(find "$ROOT/tests/memory" -maxdepth 1 -type f -name '*.php' | sort)
[ "${#cases[@]}" -gt 0 ] || { echo "FAIL: no cases under tests/memory/" >&2; exit 2; }

failures=0
for case_file in "${cases[@]}"; do
	case_name="$(basename "$case_file")"
	for mode in default no-zendmm; do
		label="$case_name [$mode]"
		cmd=("${VALGRIND[@]}" "$PHP_BIN" -n -d "extension=$SO" "$case_file")
		if [ "$mode" = "no-zendmm" ]; then
			if ! USE_ZEND_ALLOC=0 "${cmd[@]}" >/tmp/rsp-mem-out.log 2>&1; then
				echo "FAIL  $label" >&2
				cat /tmp/rsp-mem-out.log >&2
				failures=$((failures + 1))
				continue
			fi
		else
			if ! "${cmd[@]}" >/tmp/rsp-mem-out.log 2>&1; then
				echo "FAIL  $label" >&2
				cat /tmp/rsp-mem-out.log >&2
				failures=$((failures + 1))
				continue
			fi
		fi
		echo "PASS  $label"
	done
done

[ "$failures" -eq 0 ] || {
	echo "FAIL: $failures memory gate run(s) failed; see logs above" >&2
	exit 1
}
echo "memory gate: ${#cases[@]} case(s), both ZendMM modes, zero definite/indirect leaks"
