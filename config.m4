dnl resvg-php extension configuration.
dnl
dnl The vendored resvg renderer is linked as a static Rust archive by the build
dnl script (tools/build.sh); this file only wires headers, sources, and flags.

PHP_ARG_ENABLE([resvg],
  [whether to enable the resvg extension],
  [AS_HELP_STRING([--enable-resvg],
    [Enable resvg (SVG rasterization on a vendored resvg core)])],
  [no])

if test "$PHP_RESVG" != "no"; then

  dnl Shim headers live with the Rust bridge that owns the vendored renderer.
  dnl The build driver passes RESVG_SHIM_INCLUDE; the fallback suits an in-tree build.
  RPHP_SHIM_INCLUDE="${RESVG_SHIM_INCLUDE:-$abs_srcdir/../native/include}"
  if test ! -f "$RPHP_SHIM_INCLUDE/resvg_php_shim.h"; then
    AC_MSG_ERROR([resvg_php_shim.h not found at $RPHP_SHIM_INCLUDE; run tools/build.sh])
  fi
  PHP_ADD_INCLUDE([$RPHP_SHIM_INCLUDE])

  PHP_NEW_EXTENSION([resvg], [resvg.c resvg_renderer.c], [$ext_shared],,
    [-Wall -Wextra -Werror])

  PHP_SUBST(RESVG_SHARED_LIBADD)
fi
