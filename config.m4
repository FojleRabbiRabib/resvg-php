dnl resvg-php extension configuration.
dnl
dnl A plain `phpize && ./configure && make && make install` — the path PIE and
dnl PECL run (DESIGN §9.1) — never invokes cargo, so this file drives the Rust
dnl shim build itself: it checks the toolchain here (where build-environment
dnl checks belong), records the cargo rules that land in `Makefile.objects`,
dnl and links the resulting static archive into resvg.so.

PHP_ARG_ENABLE([resvg],
  [whether to enable the resvg extension],
  [AS_HELP_STRING([--enable-resvg],
    [Enable resvg (SVG rasterization on a vendored resvg core)])],
  [no])

if test "$PHP_RESVG" != "no"; then

  dnl Toolchain check. resvg 0.48.x is edition 2024 (MSRV 1.85); refuse a
  dnl toolchain that cannot build it with an actionable message rather than a
  dnl cryptic rustc error halfway through make. rustup installs to ~/.cargo/bin,
  dnl which is not always ahead of a distro cargo on PATH, so an MSRV-failing
  dnl PATH cargo falls back to that location before giving up.
  AC_CHECK_PROG([RESVG_CARGO], [cargo], [cargo], [no])
  if test "$RESVG_CARGO" = "no"; then
    AC_MSG_ERROR([cargo not found. resvg builds its vendored renderer from Rust source and needs a Rust toolchain >= 1.85 (resvg 0.48.x MSRV); install rustup and re-run configure.])
  fi

  resvg_cargo_ok() {
    test -n "$1" || return 1
    v=`"$1" --version 2>/dev/null | awk '{ print $2 }'`
    major=`printf '%s' "$v" | cut -d. -f1`
    minor=`printf '%s' "$v" | cut -d. -f2`
    test -n "$major" && test "$major" -ge 1 || return 1
    test "$major" -gt 1 || test "$minor" -ge 85
  }

  RESVG_CARGO_VERSION=`$RESVG_CARGO --version 2>/dev/null | awk '{ print $2 }'`
  if ! resvg_cargo_ok "$RESVG_CARGO"; then
    if test -x "$HOME/.cargo/bin/cargo" && resvg_cargo_ok "$HOME/.cargo/bin/cargo"; then
      RESVG_CARGO="$HOME/.cargo/bin/cargo"
      RESVG_CARGO_VERSION=`$RESVG_CARGO --version 2>/dev/null | awk '{ print $2 }'`
    else
      AC_MSG_ERROR([cargo $RESVG_CARGO_VERSION is older than the resvg 0.48.x MSRV of 1.85. Install a current toolchain with rustup and re-run configure.])
    fi
  fi

  dnl Shim headers live with the Rust bridge that owns the vendored renderer.
  dnl The build driver passes RESVG_SHIM_INCLUDE; the fallback suits the §3 root
  dnl layout, where native/ is a subdirectory of the repository root.
  RPHP_SHIM_INCLUDE="${RESVG_SHIM_INCLUDE:-$abs_srcdir/native/include}"
  if test ! -f "$RPHP_SHIM_INCLUDE/resvg_php_shim.h"; then
    AC_MSG_ERROR([resvg_php_shim.h not found at $RPHP_SHIM_INCLUDE])
  fi
  PHP_ADD_INCLUDE([$RPHP_SHIM_INCLUDE])

  dnl §9's C hardening belongs here, not only in tools/build.sh: this configure
  dnl path is the canonical artifact path (§9.1), so a PIE/PECL/distro source
  dnl build must produce the same hardened object as the driver. No -O2 is added
  dnl here — PHP's own default CFLAGS already carry it, and adding it would
  dnl override a DEBUG build's -O0.
  RESVG_HARDEN_CFLAGS="-fstack-protector-strong -fstack-clash-protection -fvisibility=hidden"

  dnl _FORTIFY_SOURCE=3 where the toolchain supports it, =2 otherwise. The -U is
  dnl required: distro GCC predefines it, and redefining to a different value is a
  dnl diagnostic on its own.
  AC_MSG_CHECKING([whether the C toolchain supports _FORTIFY_SOURCE=3])
  resvg_save_CFLAGS="$CFLAGS"
  CFLAGS="$CFLAGS -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3"
  AC_COMPILE_IFELSE(
    [AC_LANG_PROGRAM([[#include <string.h>]],
      [[char b[16]; strcpy(b, "abc"); return (int)strlen(b);]])],
    [RESVG_FORTIFY=3], [RESVG_FORTIFY=2])
  CFLAGS="$resvg_save_CFLAGS"
  AC_MSG_RESULT([$RESVG_FORTIFY])
  RESVG_HARDEN_CFLAGS="$RESVG_HARDEN_CFLAGS -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=$RESVG_FORTIFY"

  dnl CET is an x86-64 facility; applying it on another Tier 1 target is
  dnl meaningless, so it is gated on the host CPU rather than unconditional.
  case "$host_cpu" in
    x86_64|amd64) RESVG_HARDEN_CFLAGS="$RESVG_HARDEN_CFLAGS -fcf-protection=full" ;;
  esac

  PHP_NEW_EXTENSION([resvg], [resvg.c resvg_options.c resvg_exception.c resvg_renderer.c resvg_document.c], [$ext_shared],,
    [-Wall -Wextra -Werror -Wformat -Wformat-security $RESVG_HARDEN_CFLAGS])

  dnl The static archive is built by the rules recorded in Makefile.frag (they
  dnl are appended into the generated Makefile.objects) and linked after the
  dnl extension objects, so every resvg_php_* symbol resolves inside resvg.so.
  dnl Both paths are overridable for out-of-tree builds; the defaults suit a
  dnl plain `phpize && ./configure` at the §3 root layout.
  RESVG_NATIVE_DIR="${RESVG_NATIVE_DIR:-$abs_srcdir/native}"
  RESVG_ARCHIVE="${RESVG_ARCHIVE:-$RESVG_NATIVE_DIR/target/release/libresvg_php.a}"

  dnl The shim's Cargo.toml points at the pinned, hash-verified vendored source,
  dnl which is gitignored and fetched only by tools/build.sh. Without this check a
  dnl clean checkout dies mid-make with a cryptic cargo "path not found" — the
  dnl failure mode the toolchain check above exists to prevent, in the same shape.
  RESVG_VENDOR_DIR="${RESVG_VENDOR_DIR:-$abs_srcdir/vendor-src}"
  if test ! -f "$RESVG_VENDOR_DIR/resvg-0.48.1/crates/resvg/Cargo.toml"; then
    AC_MSG_ERROR([vendored resvg source is missing at $RESVG_VENDOR_DIR. It is fetched and SHA-256-verified by tools/build.sh; run that once (or fetch it there) before building.])
  fi

  dnl §9 link hardening and the export map, so the canonical link hides the
  dnl internal symbols and matches tools/build.sh's relink. `resvg.map` exports
  dnl exactly `get_module`.
  RESVG_LINK_SCRIPT="$abs_srcdir/resvg.map"
  if test ! -f "$RESVG_LINK_SCRIPT"; then
    AC_MSG_ERROR([resvg.map not found at $RESVG_LINK_SCRIPT; it is part of the extension sources])
  fi
  RESVG_SHARED_LIBADD="$RESVG_SHARED_LIBADD $RESVG_ARCHIVE -Wl,--version-script=$RESVG_LINK_SCRIPT -Wl,--gc-sections -Wl,-z,relro,-z,now,-z,noexecstack"

  PHP_ADD_MAKEFILE_FRAGMENT
  PHP_SUBST(RESVG_CARGO)
  PHP_SUBST(RESVG_NATIVE_DIR)
  PHP_SUBST(RESVG_ARCHIVE)
  PHP_SUBST(RESVG_SHARED_LIBADD)
fi
