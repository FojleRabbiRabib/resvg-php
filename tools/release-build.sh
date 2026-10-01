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
#      ABIS (space-separated subset, default: "8.3 8.4 8.5"),
#      LIBC (glibc | musl; default: detected from `ldd --version`),
#      RELEASE_TAG (optional, e.g. v0.1.0+resvg.0.48.1 — PIE resolves packages by the
#      full tag version, so archives are additionally published under that name).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/build/dist}"
ARCH="${ARCH:-$(uname -m)}"

# PIE encodes the libc flavour in the archive name; detect it from the build
# host when the caller has not pinned it. The musl dynamic loader is the
# filesystem marker for Alpine — parsing `ldd --version` would not do, since
# musl's ldd exits non-zero under `set -o pipefail` even as it prints the
# banner.
if [ -n "${LIBC:-}" ]; then
	case "$LIBC" in
		glibc|musl) ;;
		*) echo "FAIL: unsupported LIBC '$LIBC' (supported: glibc, musl)" >&2; exit 2 ;;
	esac
elif ls /lib/ld-musl-*.so.* >/dev/null 2>&1; then
	LIBC=musl
else
	LIBC=glibc
fi

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
	PIE_ZIP_NAME="php_resvg-${EXT_VERSION}_php${php_ver}-${ARCH}-linux-${LIBC}-nts.zip"
	TMP_STAGE="$(mktemp -d)"
	cp "$SRC_SO" "$TMP_STAGE/resvg.so"
	(
		cd "$TMP_STAGE"
		zip -q -9 "$OUT_DIR/$PIE_ZIP_NAME" resvg.so
	)
	rm -rf "$TMP_STAGE"
	echo "   packaged PIE asset: $PIE_ZIP_NAME"

	# PIE resolves the package by the tag's full version (pretty version, e.g.
	# v0.1.0+resvg.0.48.1), so publish the identical archive under that name too;
	# PIE lowercases its expectation, so the alternate name is lowercased to match
	# under either strict or case-folded comparison.
	if [ -n "${RELEASE_TAG:-}" ]; then
		PIE_TAG_ZIP_NAME="$(printf 'php_resvg-%s_php%s-%s-linux-%s-nts.zip' \
			"$RELEASE_TAG" "$php_ver" "$ARCH" "$LIBC" | tr '[:upper:]' '[:lower:]')"
		cp "$OUT_DIR/$PIE_ZIP_NAME" "$OUT_DIR/$PIE_TAG_ZIP_NAME"
		echo "   packaged PIE asset (tag-version name): $PIE_TAG_ZIP_NAME"
	fi

	# 2. Direct-download bare .so. The glibc name is the original published
	# spelling; musl artifacts carry the libc in the name so the two families
	# cannot collide.
	if [ "$LIBC" = "musl" ]; then
		BARE_SO_NAME="resvg-php${php_ver}-linux-musl-${ARCH}.so"
	else
		BARE_SO_NAME="resvg-php${php_ver}-linux-${ARCH}.so"
	fi
	cp "$SRC_SO" "$OUT_DIR/$BARE_SO_NAME"
	echo "   emitted bare asset: $BARE_SO_NAME"

	# 3. Provenance record:
	PHP_CONFIG_BIN="php-config$php_ver"
	command -v "$PHP_CONFIG_BIN" >/dev/null 2>&1 || PHP_CONFIG_BIN=php-config
	PHP_INC="$("$PHP_CONFIG_BIN" --include-dir 2>/dev/null || echo "")"
	PHP_API="$(awk '$1 == "#define" && $2 == "ZEND_MODULE_API_NO" { print $3; exit }' \
		"$PHP_INC/Zend/zend_modules.h" 2>/dev/null || echo "unknown")"
	SO_SHA="$(sha256sum "$SRC_SO" | awk '{print $1}')"
	GIT_REV="$(git rev-parse HEAD 2>/dev/null || echo "unknown")"

	# The provenance file name carries the libc for musl so the two families
	# cannot collide; glibc keeps the original published spelling.
	if [ "$LIBC" = "musl" ]; then
		PROV_NAME="resvg-php${php_ver}-${ARCH}-musl.provenance"
	else
		PROV_NAME="resvg-php${php_ver}-${ARCH}.provenance"
	fi
	cat > "$OUT_DIR/$PROV_NAME" <<-EOF
	version=$EXT_VERSION
	php=$php_ver
	php_api=$PHP_API
	arch=$ARCH
	libc=$LIBC
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
