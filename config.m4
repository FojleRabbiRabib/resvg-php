dnl resvg-php extension configuration.
dnl
dnl A plain `phpize && ./configure && make && make install` — the path PIE and
dnl PECL run — never invokes cargo, so this file drives the Rust
dnl shim build itself: it checks the toolchain here (where build-environment
dnl checks belong), records the cargo rules that land in `Makefile.objects`,
dnl and links the resulting static archive into resvg.so.

PHP_ARG_ENABLE([resvg],
  [whether to enable the resvg extension],
  [AS_HELP_STRING([--enable-resvg],
    [Enable resvg (SVG rasterization on a vendored resvg core)])],
  [no])

PHP_ARG_ENABLE([resvg-offline],
  [whether to build the resvg extension without network access],
  [AS_HELP_STRING([--enable-resvg-offline],
    [Resolve Rust crates from native/vendor-crates instead of crates.io])],
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
  dnl The build driver passes RESVG_SHIM_INCLUDE; the fallback suits the root
  dnl layout, where native/ is a subdirectory of the repository root.
  RPHP_SHIM_INCLUDE="${RESVG_SHIM_INCLUDE:-$abs_srcdir/native/include}"
  if test ! -f "$RPHP_SHIM_INCLUDE/resvg_php_shim.h"; then
    AC_MSG_ERROR([resvg_php_shim.h not found at $RPHP_SHIM_INCLUDE])
  fi
  PHP_ADD_INCLUDE([$RPHP_SHIM_INCLUDE])

  dnl The C hardening belongs here, not only in tools/build.sh: this configure
  dnl path is the canonical artifact path, so a PIE/PECL/distro source
  dnl build must produce the same hardened object as the driver. No -O2 is added
  dnl here — PHP's own default CFLAGS already carry it, and adding it would
  dnl override a DEBUG build's -O0.
  RESVG_HARDEN_CFLAGS="-fstack-protector-strong -fvisibility=hidden"

  dnl Stack-clash protection where the toolchain supports the flag. Apple clang
  dnl accepts the flag on arm64 but warns "argument unused"; the extension builds
  dnl with -Werror, so the probe must too, or a warning-level rejection becomes a
  dnl hard build failure.
  AC_MSG_CHECKING([whether the C toolchain supports -fstack-clash-protection])
  resvg_save_CFLAGS="$CFLAGS"
  CFLAGS="$CFLAGS -Werror -fstack-clash-protection"
  AC_COMPILE_IFELSE(
    [AC_LANG_PROGRAM([], [[return 0;]])],
    [resvg_clash=yes], [resvg_clash=no])
  CFLAGS="$resvg_save_CFLAGS"
  AC_MSG_RESULT([$resvg_clash])
  if test "$resvg_clash" = "yes"; then
    RESVG_HARDEN_CFLAGS="$RESVG_HARDEN_CFLAGS -fstack-clash-protection"
  fi

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

  dnl CET is an x86-64 facility on ELF platforms; applying it on another Tier 1
  dnl target is meaningless, and Apple clang (darwin x86_64) rejects the flag.
  case "$host_cpu:$host_os" in
    x86_64:darwin*|amd64:darwin*) ;;
    x86_64:*|amd64:*) RESVG_HARDEN_CFLAGS="$RESVG_HARDEN_CFLAGS -fcf-protection=full" ;;
  esac

  PHP_NEW_EXTENSION([resvg], [resvg.c resvg_options.c resvg_exception.c resvg_renderer.c resvg_document.c], [$ext_shared],,
    [-Wall -Wextra -Werror -Wformat -Wformat-security $RESVG_HARDEN_CFLAGS])

  dnl The static archive is built by the rules recorded in Makefile.frag (they
  dnl are appended into the generated Makefile.objects) and linked after the
  dnl extension objects, so every resvg_php_* symbol resolves inside resvg.so.
  dnl Both paths are overridable for out-of-tree builds; the defaults suit a
  dnl plain `phpize && ./configure` at the root layout.
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

  dnl Offline mode: crates resolve from native/vendor-crates (created by
  dnl tools/vendor-offline.sh) and cargo runs --frozen so it fails loudly
  dnl rather than reaching for the network.
  RESVG_CARGO_FLAGS="--locked"
  if test "$PHP_RESVG_OFFLINE" != "no"; then
    RESVG_CARGO_FLAGS="--frozen"
    if test ! -d "$RESVG_NATIVE_DIR/vendor-crates"; then
      AC_MSG_ERROR([offline build requested but $RESVG_NATIVE_DIR/vendor-crates is absent; create it with tools/vendor-offline.sh.])
    fi
  fi

  dnl Link hardening and the export map, so the canonical link hides the
  dnl internal symbols and matches tools/build.sh's relink. On ELF (Linux/musl)
  dnl `resvg.map` exports exactly `get_module`; on Mach-O (macOS) ld64 takes
  dnl `-exported_symbols_list` over `resvg.exp` (same single entry), with
  dnl `-dead_strip` and `-bind_at_load` in place of the GNU -z pair.
  dnl
  dnl `-undefined dynamic_lookup` is required on Mach-O: unlike ELF, ld64
  dnl resolves every undefined symbol at link time unless told otherwise, and
  dnl the Zend API symbols this extension calls are provided by the php binary
  dnl that loads it, not by any library on the link line.
  case "$host_os" in
    darwin*)
      RESVG_EXPORTS_LIST="$abs_srcdir/resvg.exp"
      if test ! -f "$RESVG_EXPORTS_LIST"; then
        AC_MSG_ERROR([resvg.exp not found at $RESVG_EXPORTS_LIST; it is part of the extension sources])
      fi
      RESVG_SHARED_LIBADD="$RESVG_SHARED_LIBADD $RESVG_ARCHIVE -Wl,-dead_strip -Wl,-bind_at_load -Wl,-undefined,dynamic_lookup -Wl,-exported_symbols_list,$RESVG_EXPORTS_LIST"
      ;;
    *)
      RESVG_LINK_SCRIPT="$abs_srcdir/resvg.map"
      if test ! -f "$RESVG_LINK_SCRIPT"; then
        AC_MSG_ERROR([resvg.map not found at $RESVG_LINK_SCRIPT; it is part of the extension sources])
      fi
      RESVG_SHARED_LIBADD="$RESVG_SHARED_LIBADD $RESVG_ARCHIVE -Wl,--version-script=$RESVG_LINK_SCRIPT -Wl,--gc-sections -Wl,-z,relro,-z,now,-z,noexecstack"
      ;;
  esac

  PHP_ADD_MAKEFILE_FRAGMENT
  PHP_SUBST(RESVG_CARGO)
  PHP_SUBST(RESVG_CARGO_FLAGS)
  PHP_SUBST(RESVG_NATIVE_DIR)
  PHP_SUBST(RESVG_ARCHIVE)
  PHP_SUBST(RESVG_SHARED_LIBADD)
fi
