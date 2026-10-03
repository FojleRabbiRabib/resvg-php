/*
 * resvg-php — module header: identity, version, and the INI-backed globals.
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef PHP_RESVG_H
#define PHP_RESVG_H

extern zend_module_entry resvg_module_entry;
#define phpext_resvg_ptr &resvg_module_entry

/* Packaging version: plain semver, valid in package.xml and version_compare. */
#define PHP_RESVG_VERSION "0.3.0"
#define PHP_RESVG_EXTNAME "resvg"

ZEND_BEGIN_MODULE_GLOBALS(resvg)
zend_long max_input_size;
zend_long max_render_pixels;
ZEND_END_MODULE_GLOBALS(resvg)

ZEND_EXTERN_MODULE_GLOBALS(resvg)

#define RESVG_G(v) ZEND_MODULE_GLOBALS_ACCESSOR(resvg, v)

#if defined(ZTS) && defined(COMPILE_DL_RESVG)
ZEND_TSRMLS_CACHE_EXTERN()
#endif

#endif /* PHP_RESVG_H */
