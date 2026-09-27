/*
 * resvg-php — SVG rendering for PHP on a vendored resvg (Rust) core.
 */

#ifndef RESVG_PRIVATE_H
#define RESVG_PRIVATE_H

#include "php.h"
#include "resvg_php_shim.h"

/* Status codes reported by the Rust shim (see native/include/resvg_php_shim.h). */
#define RESVG_STATUS_OK 0
#define RESVG_STATUS_NULL_POINTER 1
#define RESVG_STATUS_UTF8 2
#define RESVG_STATUS_INVALID_SIZE 3
#define RESVG_STATUS_PARSING 4
#define RESVG_STATUS_ALLOCATION 5
#define RESVG_STATUS_ENCODE 6
#define RESVG_STATUS_INTERNAL 7
#define RESVG_STATUS_INVALID_ARGUMENT 8

/* Library defaults, mirrored from usvg::Options::default(). */
#define RESVG_DEFAULT_DPI 96.0
#define RESVG_DEFAULT_FONT_FAMILY "Times New Roman"
#define RESVG_DEFAULT_FONT_SIZE 12.0
#define RESVG_DEFAULT_LANGUAGES "en"

/* A re-usable parse/render configuration owning the font database. The shim handle
 * is built once in the constructor; rebuilding it means re-scanning system fonts. */
typedef struct _resvg_renderer_object {
	resvg_php_options *handle;
	zend_object std;
} resvg_renderer_object;

static zend_always_inline resvg_renderer_object *resvg_renderer_from_obj(zend_object *obj)
{
	return (resvg_renderer_object *)((char *)(obj)-XtOffsetOf(resvg_renderer_object, std));
}

#define Z_RESVG_RENDERER_P(zv) resvg_renderer_from_obj(Z_OBJ_P(zv))

extern zend_class_entry *resvg_renderer_ce;

zend_result resvg_register_renderer_class(void);

/* Shared by the class methods and the procedural helpers. */
void resvg_render_or_throw(resvg_renderer_object *renderer, zend_string *svg, HashTable *options, zval *return_value);
void resvg_measure_or_throw(resvg_renderer_object *renderer, zend_string *svg, HashTable *options, zval *return_value);

#endif /* RESVG_PRIVATE_H */
