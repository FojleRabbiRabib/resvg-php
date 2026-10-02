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
#      LIBC (glibc | musl | bsdlibc; default: detected from the build host),
#      TS (nts | zts; default: nts — PIE matches the thread-safety segment),
#      RELEASE_TAG (optional, e.g. v0.2.0 — PIE resolves packages by the
#      full tag version, so archives are additionally published under that name).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/build/dist}"
ARCH="${ARCH:-$(uname -m)}"

# PIE's asset name carries the thread-safety segment bracket (`-nts` or `-zts`);
# a ZTS PHP install resolves only the `-zts` spelling.
TS="${TS:-nts}"
case "$TS" in
	nts|zts) ;;
	*) echo "FAIL: unsupported TS '$TS' (supported: nts, zts)" >&2; exit 2 ;;
esac

# PIE encodes the OS family in the archive name (linux, darwin, ...).
OS_NAME="$(uname -s)"
case "$OS_NAME" in
	Linux) OS_SEG="${OS_SEG:-linux}" ;;
	Darwin) OS_SEG="${OS_SEG:-darwin}" ;;
	*) echo "FAIL: unsupported OS '$OS_NAME' (supported: Linux, Darwin)" >&2; exit 2 ;;
esac

# PIE names archives after its normalized architecture enum: aarch64 hosts
# resolve to `arm64` (PhpBinaryPath parses php_uname("m") through the
# Architecture enum), so aarch64 artifacts must also be published under that
# spelling or PIE never finds them.
PIE_ARCH="${ARCH/aarch64/arm64}"

# PIE encodes the libc flavour in the archive name; detect it from the build
# host when the caller has not pinned it. macOS has no glibc/musl split — PIE
# reports `bsdlibc` there. The musl dynamic loader is the filesystem marker
# for Alpine — parsing `ldd --version` would not do, since musl's ldd exits
# non-zero under `set -o pipefail` even as it prints the banner.
if [ -n "${LIBC:-}" ]; then
	case "$LIBC" in
		glibc|musl|bsdlibc) ;;
		*) echo "FAIL: unsupported LIBC '$LIBC' (supported: glibc, musl, bsdlibc)" >&2; exit 2 ;;
	esac
elif [ "$OS_SEG" = "darwin" ]; then
	LIBC=bsdlibc
elif ls /lib/ld-musl-*.so.* >/dev/null 2>&1; then
	LIBC=musl
else
	LIBC=glibc
fi

command -v zip >/dev/null 2>&1 || {
	echo "FAIL: zip utility not found; install zip" >&2
	exit 1
}

# SHA-256 calculator: `sha256sum` on Linux, `shasum -a 256` on macOS / BSD.
calc_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		echo "FAIL: neither sha256sum nor shasum found" >&2
		exit 1
	fi
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
	# {Arch} is PIE's normalized enum spelling (arm64, never aarch64) and {OS}
	# the OS family (linux, darwin). Archive must contain `resvg.so`.
	PIE_ZIP_NAME="php_resvg-${EXT_VERSION}_php${php_ver}-${PIE_ARCH}-${OS_SEG}-${LIBC}-${TS}.zip"
	TMP_STAGE="$(mktemp -d)"
	cp "$SRC_SO" "$TMP_STAGE/resvg.so"
	(
		cd "$TMP_STAGE"
		zip -q -9 "$OUT_DIR/$PIE_ZIP_NAME" resvg.so
	)
	rm -rf "$TMP_STAGE"
	echo "   packaged PIE asset: $PIE_ZIP_NAME"

	# Host arch name alias. PIE looks for the normalized `arm64` spelling, but
	# `uname -m` reports `aarch64` on Linux ARM hosts; the alias keeps direct
	# downloaders who expect the host spelling working too.
	if [ "$PIE_ARCH" != "$ARCH" ]; then
		ALIAS_ZIP_NAME="$(printf 'php_resvg-%s_php%s-%s-%s-%s-%s.zip' \
			"$EXT_VERSION" "$php_ver" "$ARCH" "$OS_SEG" "$LIBC" "$TS" | tr '[:upper:]' '[:lower:]')"
		cp "$OUT_DIR/$PIE_ZIP_NAME" "$OUT_DIR/$ALIAS_ZIP_NAME"
		echo "   packaged PIE asset (host-arch alias): $ALIAS_ZIP_NAME"
	fi

	# PIE resolves the package by the tag's full version (pretty version, e.g.
	# v0.2.0), so publish the identical archive under that name too;
	# PIE lowercases its expectation, so the alternate name is lowercased to match
	# under either strict or case-folded comparison.
	if [ -n "${RELEASE_TAG:-}" ]; then
		PIE_TAG_ZIP_NAME="$(printf 'php_resvg-%s_php%s-%s-%s-%s-%s.zip' \
			"$RELEASE_TAG" "$php_ver" "$PIE_ARCH" "$OS_SEG" "$LIBC" "$TS" | tr '[:upper:]' '[:lower:]')"
		cp "$OUT_DIR/$PIE_ZIP_NAME" "$OUT_DIR/$PIE_TAG_ZIP_NAME"
		echo "   packaged PIE asset (tag-version name): $PIE_TAG_ZIP_NAME"
		if [ "$PIE_ARCH" != "$ARCH" ]; then
			PIE_TAG_ALIAS_NAME="$(printf 'php_resvg-%s_php%s-%s-%s-%s-%s.zip' \
				"$RELEASE_TAG" "$php_ver" "$ARCH" "$OS_SEG" "$LIBC" "$TS" | tr '[:upper:]' '[:lower:]')"
			cp "$OUT_DIR/$PIE_ZIP_NAME" "$OUT_DIR/$PIE_TAG_ALIAS_NAME"
			echo "   packaged PIE asset (tag-version host-arch alias): $PIE_TAG_ALIAS_NAME"
		fi
	fi

	# 2. Direct-download bare .so. The glibc Linux name is the original
	# published spelling; musl and macOS artifacts carry their platform in the
	# name so the families cannot collide.
	if [ "$OS_SEG" = "darwin" ]; then
		BARE_SO_NAME="resvg-php${php_ver}-darwin-${ARCH}.so"
	elif [ "$LIBC" = "musl" ]; then
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
	SO_SHA="$(calc_sha256 "$SRC_SO")"
	# Containers mount the work tree under a different owner, so git refuses to
	# read it ("dubious ownership") and the revision would silently degrade to
	# `unknown`; callers that know it (CI passes the commit SHA) set GIT_REV.
	GIT_REV="${GIT_REV:-$(git rev-parse HEAD 2>/dev/null || echo "unknown")}"

	# The provenance file name carries the platform for musl and macOS so the
	# families cannot collide; glibc Linux keeps the original spelling.
	if [ "$OS_SEG" = "darwin" ]; then
		PROV_NAME="resvg-php${php_ver}-darwin-${ARCH}.provenance"
	elif [ "$LIBC" = "musl" ]; then
		PROV_NAME="resvg-php${php_ver}-${ARCH}-musl.provenance"
	else
		PROV_NAME="resvg-php${php_ver}-${ARCH}.provenance"
	fi
	cat > "$OUT_DIR/$PROV_NAME" <<-EOF
	version=$EXT_VERSION
	php=$php_ver
	php_api=$PHP_API
	arch=$ARCH
	os=$OS_SEG
	libc=$LIBC
	commit=$GIT_REV
	sha256=$SO_SHA
	EOF
done

echo "==> Generating SHA256SUMS"
(
	cd "$OUT_DIR"
	# `sha256sum` on Linux, `shasum -a 256` on macOS; both print
	# "<hash>  <name>", which is what the matching verifier consumes.
	if command -v sha256sum >/dev/null 2>&1; then
		find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -print | sort | xargs sha256sum > /tmp/rsp-sums.tmp
	else
		find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -print | sort | xargs shasum -a 256 > /tmp/rsp-sums.tmp
	fi
	mv /tmp/rsp-sums.tmp SHA256SUMS
)

echo ">> Release assets assembled in $OUT_DIR:"
ls -lh "$OUT_DIR"
