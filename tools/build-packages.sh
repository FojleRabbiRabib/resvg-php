#!/usr/bin/env bash
# tools/build-packages.sh — build the deb and rpm distro packages.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# Runs INSIDE a build container with the repository mounted at /src. Both
# packages build from the offline source bundle (the air-gapped tarball), so
# neither needs network access, and both go through the canonical phpize path.
# The rpm path targets EL8+ with Remi PHP (rpmbuild + php-devel); the deb path
# targets Debian/Ubuntu (php8.N-dev, dpkg-deb, phpenmod wiring).
#
# Usage: tools/build-packages.sh 8.3|8.4|8.5 [rpm|deb]
set -euo pipefail

PHPV="${1:?usage: tools/build-packages.sh 8.3|8.4|8.5 [rpm|deb]}"
KIND="${2:-all}"
case "$PHPV" in 8.3|8.4|8.5) ;; *) echo "FAIL: unsupported PHP version '$PHPV'" >&2; exit 2 ;; esac
case "$KIND" in rpm|deb|all) ;; *) echo "FAIL: unsupported kind '$KIND'" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/build/dist"
# The packaged module must pass the same ELF gates as the release prebuilts.
# The floor is the oldest glibc the package promises to load on: EL8 for the
# rpm (its module loads on EL8/EL9 and anything newer), Noble for the deb
# (api-dir packages target one distro release, hence the ~noble suffix).
source "$ROOT/tools/elf-gates.sh"
RPM_GLIBC_FLOOR=2.28
DEB_GLIBC_FLOOR=2.39
mkdir -p "$DIST"

VERSION="$(awk -F'"' '/#define PHP_RESVG_VERSION/ {print $2}' "$ROOT/php_resvg.h")"
[ -n "$VERSION" ] || { echo "FAIL: could not determine PHP_RESVG_VERSION" >&2; exit 1; }

bundle="$DIST/resvg-php-${VERSION}-offline.tar.gz"
if [ ! -f "$bundle" ]; then
	echo ">> building the offline source bundle"
	OUT_DIR="$DIST" bash "$ROOT/tools/vendor-offline.sh" --tarball
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

build_rpm() {
	echo ">> building rpm for PHP $PHPV"
	command -v rpmbuild >/dev/null 2>&1 || {
		echo "FAIL: rpmbuild not found; the rpm path runs in an EL8 container" >&2
		exit 2
	}
	sed "s/@VERSION@/$VERSION/g" "$ROOT/packaging/rpm/php-pecl-resvg.spec.in" \
		> "$work/php-pecl-resvg.spec"

	# A private _topdir keeps BUILD, BUILDROOT, and RPMS together under $work,
	# so the module can be gated where %install put it and the finished rpm
	# collected from one known place.
	local top="$work/top"
	mkdir -p "$top/BUILD" "$top/BUILDROOT" "$top/RPMS" "$top/SRPMS" "$top/SOURCES" "$top/SPECS"
	cp -p "$bundle" "$top/SOURCES/"

	# --noclean preserves BUILDROOT: rpmbuild deletes it as its last act, and
	# the gate below inspects exactly the module %install staged there.
	rpmbuild -bb --noclean \
		--define "_topdir $top" \
		--define "_specdir $work" \
		"$work/php-pecl-resvg.spec"

	# Gate the bytes %install staged — the same module the rpm ships — before
	# the rpm is published. A failure here leaves it out of build/dist.
	local built
	built="$(find "$top/BUILDROOT" -name resvg.so -type f -print -quit)"
	[ -n "$built" ] || { echo "FAIL: no resvg.so in the rpm buildroot" >&2; exit 1; }
	GLIBC_FLOOR="$RPM_GLIBC_FLOOR" assert_elf_artifact "$built"

	find "$top/RPMS" -name '*.rpm' -exec cp -p {} "$DIST/" \;
}

build_deb() {
	echo ">> building deb for PHP $PHPV"
	command -v dpkg-deb >/dev/null 2>&1 || {
		echo "FAIL: dpkg-deb not found; the deb path runs in a Debian/Ubuntu container" >&2
		exit 2
	}
	local php_config="php-config$PHPV"
	command -v "$php_config" >/dev/null 2>&1 || php_config="php-config"
	command -v "$php_config" >/dev/null 2>&1 || {
		echo "FAIL: php-config for PHP $PHPV not found; install php${PHPV}-dev" >&2
		exit 2
	}

	# The extension directory is ABI-named (/usr/lib/php/<api>), and the API
	# number is the basename of the include dir — `php-config --phpapi` is not
	# implemented by every packaging.
	local include_dir ext_dir api_no
	include_dir="$("$php_config" --include-dir)"
	ext_dir="$("$php_config" --extension-dir)"
	api_no="$(basename "$include_dir")"
	case "$api_no" in
		20*|19*) ;;
		*) echo "FAIL: implausible PHP API number '$api_no' from $php_config" >&2; exit 1 ;;
	esac

	# Debian/Ubuntu pecl packaging: one source package per PHP API, installed
	# into that API's extension dir with the shared mods-available ini. phpenmod
	# only wires versions whose api dir actually contains the module, so other
	# ABIs stay untouched.
	local stage="$work/php-resvg"
	local debarch
	case "$(uname -m)" in
		x86_64) debarch=amd64 ;;
		aarch64) debarch=arm64 ;;
		*) echo "FAIL: unsupported architecture '$(uname -m)' for deb" >&2; exit 2 ;;
	esac

	mkdir -p "$stage/DEBIAN" "$stage$ext_dir" \
		"$stage/etc/php/$PHPV/mods-available" \
		"$stage/usr/share/doc/php${PHPV}-resvg"
	sed -e "s/@VERSION@/$VERSION/g" -e "s/@ARCH@/$debarch/g" -e "s/@PHPV@/$PHPV/g" \
		"$ROOT/packaging/deb/control.in" > "$stage/DEBIAN/control"
	sed "s/@PHPV@/$PHPV/g" "$ROOT/packaging/deb/postinst.in" > "$stage/DEBIAN/postinst"
	sed "s/@PHPV@/$PHPV/g" "$ROOT/packaging/deb/prerm.in" > "$stage/DEBIAN/prerm"
	chmod 755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"
	# phpenmod resolves the module ini under the per-version directory
	# (/etc/php/<v>/mods-available); a shared /etc/php/mods-available/ is
	# ignored and the module would install but never load.
	printf 'extension=resvg.so\n' > "$stage/etc/php/$PHPV/mods-available/resvg.ini"
	# Debian policy: a package installed without its source tree still carries
	# its license text.
	cp "$ROOT/packaging/deb/copyright" "$stage/usr/share/doc/php${PHPV}-resvg/copyright"

	# The staged .so must be the gated artifact: build through the canonical
	# phpize path inside this container, exactly like a source install.
	echo ">> building the extension from the offline bundle (phpize, PHP $PHPV)"
	tar -xzf "$bundle" -C "$work"
	(
		cd "$work/resvg-php-${VERSION}-offline"
		phpize"$PHPV" >/dev/null 2>&1 || phpize >/dev/null
		./configure --enable-resvg --with-php-config="$(command -v "$php_config")" >/dev/null
		make -j"$(nproc)" >/dev/null
		install -m 755 "modules/resvg.so" "$stage$ext_dir/resvg.so"
	)
	GLIBC_FLOOR="$DEB_GLIBC_FLOOR" assert_elf_artifact "$stage$ext_dir/resvg.so"

	# A distro package is version-locked to the release whose toolchain built
	# it; the ~noble suffix keeps it from being installed onto older releases
	# whose glibc the module was never promised to run against.
	dpkg-deb --root-owner-group --build "$stage" \
		"$DIST/php${PHPV}-resvg_${VERSION}-1~noble_${debarch}.deb" >/dev/null
	echo "   built: php${PHPV}-resvg_${VERSION}-1~noble_${debarch}.deb (api $api_no)"
}

case "$KIND" in
	rpm) build_rpm ;;
	deb) build_deb ;;
	all) build_rpm; build_deb ;;
esac

echo ">> distro packages for PHP $PHPV assembled in $DIST"
