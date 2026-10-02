#!/usr/bin/env bash
# tools/build-el8.sh — bootstrap an AlmaLinux 8 build environment and build one ABI.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# Runs INSIDE an almalinux:8 container with the repository mounted at /src.
# EL8's glibc 2.28 is the release floor: building here pins the artifact's
# imported glibc symbols to 2.28 so the prebuilts load on RHEL/Alma/Rocky 8,
# Debian 10+, Ubuntu 20.04+, and Amazon Linux 2023.
#
# Usage (from the host):
#   docker run --rm -v "$PWD":/src -w /src almalinux:8 bash tools/build-el8.sh 8.3
set -euo pipefail

phpv="${1:?usage: tools/build-el8.sh 8.3|8.4|8.5}"
case "$phpv" in
	8.3|8.4|8.5) ;;
	*) echo "FAIL: unsupported PHP version '$phpv'" >&2; exit 2 ;;
esac

dnf -q install -y epel-release >/dev/null
dnf -q install -y "https://rpms.remirepo.net/enterprise/remi-release-8.rpm" >/dev/null
dnf -q module reset php -y >/dev/null 2>&1 || true
dnf -q module enable "php:remi-$phpv" -y >/dev/null
# dejavu fonts: the examples gate asserts distinct text renders, which needs a
# real font present (text renders blank on fontless containers by design).
dnf -q install -y php php-devel gcc make git curl diffutils dejavu-sans-fonts zip >/dev/null

export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
	curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
		--default-toolchain 1.98.1 >/dev/null
fi

# Shared target directories from a newer-glibc host (or a mismatched cache)
# leave binaries this container cannot execute — build scripts under
# native/target and the fidelity oracle under vendor-src — so clear both
# rather than failing with an opaque "GLIBC_2.x not found". Build scripts and
# `resvg --version` are side-effect-free probes.
probe="$(find native/target/release/build -name build-script-build -type f 2>/dev/null | head -1)"
stale=0
if [ -n "$probe" ] && ! "$probe" >/dev/null 2>&1; then
	stale=1
fi
oracle="vendor-src/resvg-0.48.1/target/release/resvg"
if [ -x "$oracle" ] && ! "$oracle" --version >/dev/null 2>&1; then
	stale=1
fi
if [ "$stale" = "1" ]; then
	echo ">> clearing stale target trees: binaries predate this container's glibc"
	rm -rf native/target vendor-src/resvg-0.48.1/target
fi

tools/build.sh "$phpv"
php "tools/test-phpt.php" "build/resvg-php$phpv.so"
tools/test-examples.sh "build/resvg-php$phpv.so"
