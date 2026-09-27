/*
 * resvg-php — SVG rendering for PHP on a vendored resvg (Rust) core.
 */

#ifndef PHP_RESVG_H
#define PHP_RESVG_H

extern zend_module_entry resvg_module_entry;
#define phpext_resvg_ptr &resvg_module_entry

#define PHP_RESVG_VERSION "0.1.0"
#define PHP_RESVG_EXTNAME "resvg"

#if defined(ZTS) && defined(COMPILE_DL_RESVG)
ZEND_TSRMLS_CACHE_EXTERN()
#endif

#endif /* PHP_RESVG_H */
