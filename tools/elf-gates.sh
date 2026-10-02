#!/usr/bin/env bash
# tools/elf-gates.sh — the ELF artifact gates, shared by every driver that
# ships a glibc .so.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# tools/build.sh sources this for its own artifacts; tools/build-packages.sh
# sources it to gate the module bytes that actually go into the rpm and deb —
# one definition, so a gate can never drift between the drivers.
#
# Usage: source tools/elf-gates.sh; assert_elf_artifact <path-to.so>
# Env: GLIBC_FLOOR (e.g. 2.28) turns the highest imported glibc symbol into a
#      hard ceiling; unset, it only reports.

assert_elf_artifact() {
	local artifact="$1"
	local exports needed library glibc_versions glibc_max

	if [ -z "$artifact" ] || [ ! -f "$artifact" ]; then
		echo "FAIL: assert_elf_artifact needs a path to an existing .so" >&2
		exit 1
	fi

	exports="$(nm -D --defined-only "$artifact" | awk '{print $3}' | sed '/^$/d' | sort -u)"
	echo "   dynamic exports: ${exports//$'\n'/ }"
	[ "$exports" = "get_module" ] || {
		echo "FAIL: dynamic export table must be exactly {get_module}" >&2
		exit 1
	}
	if nm -D --defined-only "$artifact" | awk '{print $3}' | grep -qE '^(resvg_php_|RspTree|usvg)'; then
		echo "FAIL: renderer symbols leaked into the dynamic table" >&2
		exit 1
	fi

	# POSIX-portable bracket stripping: `]` must come first in the set; the
	# backslash-escaped spelling is undefined for BusyBox awk (Alpine).
	needed="$(readelf -d "$artifact" | awk '/NEEDED/{gsub(/[][]/, "", $NF); print $NF}')"
	echo "   NEEDED: ${needed//$'\n'/ }"
	while IFS= read -r library; do
		[ -z "$library" ] && continue
		case "$library" in
			# The glibc dynamic loader's soname is arch-specific (ld-linux-x86-64.so.2
			# on x86-64, ld-linux-aarch64.so.1 on aarch64); match it by pattern. musl
			# (Alpine) merges libc and the loader into libc.musl-*.so.* / ld-musl-*.
			libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|ld-linux-*.so.*|libgcc_s.so.1) ;;
			libc.musl-*.so.*|ld-musl-*.so.*) ;;
			*) echo "FAIL: unexpected dynamic dependency: $library" >&2; exit 1 ;;
		esac
	done <<< "$needed"

	if readelf -d "$artifact" | grep -qE '\((RPATH|RUNPATH)\)'; then
		echo "FAIL: $artifact must not contain RPATH/RUNPATH" >&2
		exit 1
	fi
	readelf -W -l "$artifact" | grep -q 'GNU_RELRO' || { echo "FAIL: GNU_RELRO is absent" >&2; exit 1; }
	readelf -W -l "$artifact" | awk '/GNU_STACK/ { if ($0 ~ /E/) exit 1; found=1 } END { exit found ? 0 : 1 }' || {
		echo "FAIL: GNU_STACK is executable or absent" >&2
		exit 1
	}
	readelf -d "$artifact" | grep -qE '(BIND_NOW|FLAGS.*NOW)' || { echo "FAIL: BIND_NOW is absent" >&2; exit 1; }

	glibc_versions="$(objdump -T "$artifact" | grep -oE 'GLIBC_[0-9.]+' | sort -Vu || true)"
	glibc_max="$(printf '%s\n' "$glibc_versions" | tail -1)"
	echo "   highest imported glibc symbol: ${glibc_max:-none}"
	# Release builds on the controlled old-glibc host declare a floor
	# (GLIBC_FLOOR=2.28); the artifact must not import anything newer, so a
	# toolchain bump cannot silently raise the floor. Dev builds leave it
	# unset and only print.
	if [ -n "${GLIBC_FLOOR:-}" ] && [ -n "$glibc_max" ]; then
		# Violation iff the floor sorts strictly before the artifact's maximum:
		# when floor < max the sorted head is the floor line, not the max line.
		lowest="$(printf '%s\n%s\n' "$glibc_max" "GLIBC_$GLIBC_FLOOR" | sort -V | head -1)"
		if [ "$lowest" != "$glibc_max" ]; then
			echo "FAIL: artifact imports $glibc_max, exceeding the declared floor GLIBC_$GLIBC_FLOOR" >&2
			exit 1
		fi
		echo "   glibc floor gate OK (<= GLIBC_$GLIBC_FLOOR)"
	fi
	echo "   ELF hardening OK (RELRO, BIND_NOW, non-exec stack, no rpath)"
}
