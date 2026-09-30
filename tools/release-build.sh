#!/usr/bin/env bash
# tools/release-build.sh — assemble release assets for all supported PHP ABIs.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# Builds the extension and runs the fidelity gate for each supported PHP ABI
# (8.3, 8.4, 8.5), packages PIE-canonical zip archives wrapping `resvg.so`
# (per the PIE release archive specification), emits bare .so files for direct
# download, and generates SHA256SUMS and provenance records under build/dist/.
#
# Env: RESVG_VERSION, OUT_DIR (default: build/dist), ARCH (default: from uname -m),
#      ABIS (space-separated subset, default: "8.3 8.4 8.5").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/build/dist}"
ARCH="${ARCH:-$(uname -m)}"

command -v zip >/dev/null 2>&1 || {
	echo "FAIL: zip utility not found; install zip" >&2
	exit 1
}

read -ra ABIS <<< "${ABIS:-8.3 8.4 8.5}"
[ "${#ABIS[@]}" -gt 0 ] || {
	echo "FAIL: ABIS resolved to an empty set" >&2
	exit 2
}
for abi in "${ABIS[@]}"; do
	case "$abi" in
		8.3|8.4|8.5) ;;
		*) echo "FAIL: unsupported ABI '$abi' (supported: 8.3, 8.4, 8.5)" >&2; exit 2 ;;
	esac
done

# Extract extension version from php_resvg.h
EXT_VERSION="$(awk -F'"' '/#define PHP_RESVG_VERSION/ {print $2}' "$ROOT/php_resvg.h")"
if [ -z "$EXT_VERSION" ]; then
	echo "FAIL: could not determine PHP_RESVG_VERSION from php_resvg.h" >&2
	exit 1
fi

echo ">> Preparing release build for resvg-php v$EXT_VERSION ($ARCH)"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

for php_ver in "${ABIS[@]}"; do
	echo "==> Building and gating PHP $php_ver"
	"$ROOT/tools/build.sh" "$php_ver"

	SRC_SO="$ROOT/build/resvg-php$php_ver.so"
	if [ ! -f "$SRC_SO" ]; then
		echo "FAIL: expected build output $SRC_SO not found" >&2
		exit 1
	fi

	# 1. PIE-canonical release archive:
	# php_{ExtensionName}-{Version}_php{PhpVersion}-{Arch}-{OS}-{Libc}-{TSMode}.zip
	# Archive must contain the file named exactly `resvg.so`.
	PIE_ZIP_NAME="php_resvg-${EXT_VERSION}_php${php_ver}-${ARCH}-linux-glibc-nts.zip"
	TMP_STAGE="$(mktemp -d)"
	cp "$SRC_SO" "$TMP_STAGE/resvg.so"
	(
		cd "$TMP_STAGE"
		zip -q -9 "$OUT_DIR/$PIE_ZIP_NAME" resvg.so
	)
	rm -rf "$TMP_STAGE"
	echo "   packaged PIE asset: $PIE_ZIP_NAME"

	# 2. Direct-download bare .so:
	BARE_SO_NAME="resvg-php${php_ver}-linux-${ARCH}.so"
	cp "$SRC_SO" "$OUT_DIR/$BARE_SO_NAME"
	echo "   emitted bare asset: $BARE_SO_NAME"

	# 3. Provenance record:
	PHP_CONFIG_BIN="php-config$php_ver"
	command -v "$PHP_CONFIG_BIN" >/dev/null 2>&1 || PHP_CONFIG_BIN=php-config
	PHP_API="$("$PHP_CONFIG_BIN" --phpapi 2>/dev/null || echo "unknown")"
	SO_SHA="$(sha256sum "$SRC_SO" | awk '{print $1}')"
	GIT_REV="$(git rev-parse HEAD 2>/dev/null || echo "unknown")"

	cat > "$OUT_DIR/resvg-php${php_ver}-${ARCH}.provenance" <<-EOF
	version=$EXT_VERSION
	php=$php_ver
	php_api=$PHP_API
	arch=$ARCH
	commit=$GIT_REV
	sha256=$SO_SHA
	EOF
done

echo "==> Generating SHA256SUMS"
(
	cd "$OUT_DIR"
	find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -print | sort | xargs sha256sum > /tmp/rsp-sums.tmp
	mv /tmp/rsp-sums.tmp SHA256SUMS
)

echo ">> Release assets assembled in $OUT_DIR:"
ls -lh "$OUT_DIR"
