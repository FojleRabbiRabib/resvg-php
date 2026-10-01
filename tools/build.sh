#!/usr/bin/env bash
# tools/build.sh — build a static, symbol-isolated resvg.so for one PHP ABI.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# Three stages: fetch+verify the pinned resvg source, compile the Rust shim to a
# static archive, then build and relink the C extension with that archive inside.
#
# Env: PHP_VERSION=8.3|8.4|8.5, RESVG_VERSION, RESVG_SHA256, DEBUG=1 (unstripped
#      -g -O0 artifact), SKIP_GATE=1 (skip the load/round-trip gate), CARGO_BIN.
set -euo pipefail

RESVG_VERSION="${RESVG_VERSION:-0.48.1}"
RESVG_SHA256="${RESVG_SHA256:-40dafea6b4b9d01e9d28b6d49f1e912daf3e9055676ad9179a5a2db6e7386945}"
export RESVG_VERSION RESVG_SHA256
PHPV="${1:-${PHP_VERSION:-8.3}}"
DEBUG="${DEBUG:-0}"
SKIP_GATE="${SKIP_GATE:-0}"

case "$PHPV" in
	8.3|8.4|8.5) ;;
	*) echo "FAIL: unsupported PHP_VERSION=$PHPV (supported: 8.3, 8.4, 8.5)" >&2; exit 2 ;;
esac
case "$DEBUG" in 0|1) ;; *) echo "FAIL: DEBUG must be 0 or 1" >&2; exit 2 ;; esac
case "$SKIP_GATE" in 0|1) ;; *) echo "FAIL: SKIP_GATE must be 0 or 1" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build"
LIB="$ROOT/native/target/release/libresvg_php.a"
DEBUG_SUFFIX=""
[ "$DEBUG" = "1" ] && DEBUG_SUFFIX="-debug"
OUT="$B/resvg-php$PHPV$DEBUG_SUFFIX.so"

# Artifact format and link-edit tooling differ per kernel: ELF + GNU ld on
# Linux, Mach-O + ld64 on macOS. The extension code is identical; only the
# relink flags and the artifact gates branch on this.
OS_NAME="$(uname -s)"
case "$OS_NAME" in
	Linux) ELF_ARTIFACT=1 ;;
	Darwin) ELF_ARTIFACT="" ;;
	*) echo "FAIL: unsupported OS '$OS_NAME' (supported: Linux, Darwin)" >&2; exit 2 ;;
esac

# Extension sources live at the repository root (PECL/PIE-canonical layout).
EXT_SOURCES=(
	config.m4 php_resvg.h resvg.c resvg_options.c resvg_exception.c
	resvg_renderer.c resvg_document.c resvg.stub.php resvg_arginfo.h
	resvg_internal.h resvg.map resvg.exp Makefile.frag
)

PHP_BIN="php$PHPV"
PHPIZE_BIN="phpize$PHPV"
PHP_CONFIG_BIN="php-config$PHPV"
command -v "$PHP_BIN" >/dev/null 2>&1 || PHP_BIN=php
command -v "$PHPIZE_BIN" >/dev/null 2>&1 || PHPIZE_BIN=phpize
command -v "$PHP_CONFIG_BIN" >/dev/null 2>&1 || PHP_CONFIG_BIN=php-config
PHP_BIN_PATH="$(command -v "$PHP_BIN")"
PHPIZE_BIN_PATH="$(command -v "$PHPIZE_BIN")"
PHP_CONFIG_BIN_PATH="$(command -v "$PHP_CONFIG_BIN")"

export PATH="${CARGO_BIN:+$CARGO_BIN:}$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null 2>&1 || {
	echo "FAIL: cargo not found; install Rust >= 1.85 (resvg $RESVG_VERSION MSRV)" >&2
	exit 1
}

case "$DEBUG" in
	1) PROFILE_CFLAGS="-g -O0 -fno-omit-frame-pointer"; STRIP_FLAG="" ;;
	*) PROFILE_CFLAGS="-O2"; STRIP_FLAG="-s" ;;
esac
# The security hardening itself lives in config.m4, so the canonical
# `phpize && ./configure && make` path and this driver produce the same hardened
# object. build.sh injects only the optimization profile, which it is allowed to
# differ on (DEBUG wants -O0 and must win over config.m4's flags).
HARDEN_LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack"

verify_php_toolchain() {
	local actual_version config_api cli_api phpize_api

	actual_version="$("$PHP_BIN_PATH" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
	[ "$actual_version" = "$PHPV" ] || {
		echo "FAIL: PHP_VERSION=$PHPV selected $PHP_BIN_PATH ($actual_version)" >&2
		exit 1
	}
	# The Zend API number comes from the installed headers rather than
	# `php-config --phpapi`, which some builds (the official Docker images among
	# them) do not implement; the header exists wherever an extension can build.
	config_api="$(awk '$1 == "#define" && $2 == "ZEND_MODULE_API_NO" { print $3; exit }' \
		"$("$PHP_CONFIG_BIN_PATH" --include-dir)/Zend/zend_modules.h" 2>/dev/null)"
	cli_api="$("$PHP_BIN_PATH" -i | awk -F'=> ' '/^PHP API / {value=$2} END {print value}')"
	phpize_api="$("$PHPIZE_BIN_PATH" --version | awk -F': *' '/Zend Module Api No/ {print $2; exit}')"
	if [ -z "$config_api" ] || [ "$config_api" != "$cli_api" ] || [ "$config_api" != "$phpize_api" ]; then
		echo "FAIL: PHP tool ABI mismatch (php=$cli_api php-config=$config_api phpize=$phpize_api)" >&2
		exit 1
	fi
	echo "   PHP $PHPV ABI $config_api ($PHP_BIN_PATH)"
}

assert_macho() {
	local exports deps library

	# Export isolation: the Mach-O export trie must carry exactly `_get_module`.
	# `dyld_info -exports` reads the trie directly (immune to stripping); `nm -gU`
	# is the fallback where dyld_info is absent.
	if command -v dyld_info >/dev/null 2>&1; then
		exports="$(dyld_info -exports "$OUT" 2>/dev/null | awk 'NR>2 {print $NF}' | sed '/^$/d' | sort -u)"
	else
		exports="$(nm -gU "$OUT" | awk '{print $NF}' | sed '/^$/d' | sort -u)"
	fi
	echo "   dynamic exports: ${exports//$'\n'/ }"
	[ "$exports" = "_get_module" ] || {
		echo "FAIL: dynamic export table must be exactly {_get_module}" >&2
		exit 1
	}

	deps="$(otool -L "$OUT" | tail -n +2 | awk '{print $1}' | sed '/^$/d')"
	echo "   linked libraries: ${deps//$'\n'/ }"
	while IFS= read -r library; do
		[ -z "$library" ] && continue
		case "$library" in
			/usr/lib/libSystem.B.dylib) ;;
			*) echo "FAIL: unexpected dynamic dependency: $library" >&2; exit 1 ;;
		esac
	done <<< "$deps"

	if otool -l "$OUT" | grep -q LC_RPATH; then
		echo "FAIL: $OUT must not contain LC_RPATH" >&2
		exit 1
	fi
	codesign -v "$OUT" || { echo "FAIL: ad-hoc signature is invalid" >&2; exit 1; }
	echo "   Mach-O OK (single export, libSystem only, no rpath, valid signature)"
}

assert_elf() {
	local exports needed library glibc_versions glibc_max

	exports="$(nm -D --defined-only "$OUT" | awk '{print $3}' | sed '/^$/d' | sort -u)"
	echo "   dynamic exports: ${exports//$'\n'/ }"
	[ "$exports" = "get_module" ] || {
		echo "FAIL: dynamic export table must be exactly {get_module}" >&2
		exit 1
	}
	if nm -D --defined-only "$OUT" | awk '{print $3}' | grep -qE '^(resvg_php_|RspTree|usvg)'; then
		echo "FAIL: renderer symbols leaked into the dynamic table" >&2
		exit 1
	fi

	# POSIX-portable bracket stripping: `]` must come first in the set; the
	# backslash-escaped spelling is undefined for BusyBox awk (Alpine).
	needed="$(readelf -d "$OUT" | awk '/NEEDED/{gsub(/[][]/, "", $NF); print $NF}')"
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

	if readelf -d "$OUT" | grep -qE '\((RPATH|RUNPATH)\)'; then
		echo "FAIL: $OUT must not contain RPATH/RUNPATH" >&2
		exit 1
	fi
	readelf -W -l "$OUT" | grep -q 'GNU_RELRO' || { echo "FAIL: GNU_RELRO is absent" >&2; exit 1; }
	readelf -W -l "$OUT" | awk '/GNU_STACK/ { if ($0 ~ /E/) exit 1; found=1 } END { exit found ? 0 : 1 }' || {
		echo "FAIL: GNU_STACK is executable or absent" >&2
		exit 1
	}
	readelf -d "$OUT" | grep -qE '(BIND_NOW|FLAGS.*NOW)' || { echo "FAIL: BIND_NOW is absent" >&2; exit 1; }

	glibc_versions="$(objdump -T "$OUT" | grep -oE 'GLIBC_[0-9.]+' | sort -Vu || true)"
	glibc_max="$(printf '%s\n' "$glibc_versions" | tail -1)"
	echo "   highest imported glibc symbol: ${glibc_max:-none}"
	echo "   ELF hardening OK (RELRO, BIND_NOW, non-exec stack, no rpath)"
}

# Core count: `nproc` on Linux, `sysctl -n hw.ncpu` on macOS.
num_cpus() {
	if command -v nproc >/dev/null 2>&1; then
		nproc
	elif command -v sysctl >/dev/null 2>&1; then
		sysctl -n hw.ncpu 2>/dev/null || echo 2
	else
		echo 2
	fi
}

verify_loadable() {
	"$PHP_BIN_PATH" -n -d "extension=$OUT" -r 'exit(extension_loaded("resvg") ? 0 : 1);' || {
		echo "FAIL: $OUT does not load under PHP $PHPV" >&2
		exit 1
	}
}

verify_php_toolchain

echo ">> [1/5] fetch and verify resvg v$RESVG_VERSION"
"$ROOT/tools/fetch-resvg.sh" >/dev/null
echo "   resvg $RESVG_VERSION SHA256 OK"

echo ">> [2/5] compile the Rust shim to a static archive"
# Run cargo with the working directory inside native/, so native/rust-toolchain.toml
# governs the compiler (rustup resolves the toolchain file by walking up from the
# CWD) and the release artifact cannot float with the host's `rustup default`.
# Makefile.frag runs it the same way for the canonical `phpize && make` path.
if [ "$DEBUG" = "1" ]; then
	(cd "$ROOT/native" && cargo build --locked)
	LIB="$ROOT/native/target/debug/libresvg_php.a"
else
	(cd "$ROOT/native" && cargo build --release --locked)
fi
[ -f "$LIB" ] || { echo "FAIL: $LIB missing" >&2; exit 1; }
echo "   $(du -h "$LIB" | cut -f1) libresvg_php.a"

echo ">> [3/5] phpize + configure + make (PHP $PHPV)"
EB="$B/resvg-ext-$PHPV$DEBUG_SUFFIX"
rm -rf "$EB"
mkdir -p "$EB"
for f in "${EXT_SOURCES[@]}"; do
	cp -a "$ROOT/$f" "$EB/$f"
done
(
	cd "$EB"
	PHP_CONFIG="$PHP_CONFIG_BIN_PATH" "$PHPIZE_BIN_PATH" >/tmp/resvg-phpize.log 2>&1
	CFLAGS="${CFLAGS:-} $PROFILE_CFLAGS" \
		LDFLAGS="${LDFLAGS:-}" \
		RESVG_SHIM_INCLUDE="$ROOT/native/include" \
		RESVG_NATIVE_DIR="$ROOT/native" \
		RESVG_ARCHIVE="$LIB" \
		RESVG_VENDOR_DIR="$ROOT/vendor-src" \
		./configure --enable-resvg --with-php-config="$PHP_CONFIG_BIN_PATH" \
		>/tmp/resvg-configure.log 2>&1
	make -j"$(num_cpus)" >/tmp/resvg-make.log 2>&1 || {
		tail -40 /tmp/resvg-make.log >&2
		echo "FAIL: make" >&2
		exit 1
	}
) || exit 1
echo "   objects: $(find "$EB/.libs" -maxdepth 1 -name '*.o' -type f | wc -l)"

echo ">> [4/5] relink static self-contained $OUT"
mkdir -p "$B"
if [ -n "$ELF_ARTIFACT" ]; then
	gcc -shared -fPIC $STRIP_FLAG -o "$OUT" "$EB"/.libs/*.o \
		-Wl,--version-script="$ROOT/resvg.map" -Wl,--gc-sections $HARDEN_LDFLAGS \
		-Wl,--whole-archive "$LIB" -Wl,--no-whole-archive \
		-lpthread -ldl -lm -lgcc_s
else
	# macOS: PHP extensions are Mach-O bundles; ld64 pulls the archive with
	# -force_load (no --whole-archive) and exports get_module through
	# resvg.exp. Undefined symbols (the Zend API) resolve dynamically from the
	# loading process. Ad-hoc signing is mandatory on Apple Silicon —
	# unsigned code pages refuse to map.
	cc -bundle -fPIC $STRIP_FLAG -o "$OUT" "$EB"/.libs/*.o \
		-Wl,-undefined,dynamic_lookup \
		-Wl,-exported_symbols_list,"$ROOT/resvg.exp" -Wl,-dead_strip -Wl,-bind_at_load \
		-Wl,-force_load,"$LIB"
	codesign -f -s - "$OUT"
fi
echo "   built: $OUT ($(du -h "$OUT" | cut -f1))"

echo ">> [5/5] validate ABI, exports, dependencies, and loading"
verify_loadable
if [ -n "$ELF_ARTIFACT" ]; then
	assert_elf
else
	assert_macho
fi

if [ "$SKIP_GATE" = "1" ]; then
	echo "SKIP: fidelity gate requested (build verification only)."
	exit 0
fi
"$ROOT/tools/test-fidelity.sh" "$OUT"