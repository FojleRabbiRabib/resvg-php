/*
 * resvg-php — internal declarations shared across the extension translation units.
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef RESVG_INTERNAL_H
#define RESVG_INTERNAL_H

#include "php.h"
#include "resvg_php_shim.h"

/* Status codes — identical set to native/include/resvg_php_shim.h and the PHP
 * constants on Resvg\Exception. The three lists must never diverge. */
#define RESVG_STATUS_OK 0
#define RESVG_STATUS_NULL_POINTER 1
#define RESVG_STATUS_UTF8 2
#define RESVG_STATUS_INVALID_SIZE 3
#define RESVG_STATUS_PARSING 4
#define RESVG_STATUS_ALLOCATION 5
#define RESVG_STATUS_ENCODE 6
#define RESVG_STATUS_INTERNAL 7
#define RESVG_STATUS_INVALID_ARGUMENT 8
#define RESVG_STATUS_NO_SUCH_NODE 9
#define RESVG_STATUS_ZERO_SIZE_NODE 10
#define RESVG_STATUS_ELEMENTS_LIMIT 11
#define RESVG_STATUS_MALFORMED_GZIP 12
#define RESVG_STATUS_SVGZ_DISABLED 13
#define RESVG_STATUS_TOO_LARGE 14

/* Library defaults, mirrored from usvg::Options::default() and the CLI's
 * load_fonts(). PHP defaults must equal library defaults or the fidelity gate
 * stops being like-for-like. */
#define RESVG_DEFAULT_DPI 96.0
#define RESVG_DEFAULT_FONT_FAMILY "Times New Roman"
#define RESVG_DEFAULT_FONT_SIZE 12.0
#define RESVG_DEFAULT_LANGUAGES "en"

/* Operator-tunable ceilings, registered as INI entries (see resvg.c). */
#define RESVG_INI_MAX_INPUT_SIZE "resvg.max_input_size"
#define RESVG_INI_MAX_RENDER_PIXELS "resvg.max_render_pixels"
#define RESVG_DEFAULT_MAX_INPUT_SIZE (16 * 1024 * 1024)
#define RESVG_DEFAULT_MAX_RENDER_PIXELS (1 << 26)

/* A rendering-hint name -> shim discriminant pair. */
struct resvg_hint {
	const char *name;
	int32_t value;
};

/* Constructor options, resolved from the PHP array. Shared because the renderer
 * owns them and the tree inherits its behaviour from the handle they built. */
typedef struct {
	zend_string *font_family;
	zend_string *serif_family;
	zend_string *sans_serif_family;
	zend_string *cursive_family;
	zend_string *fantasy_family;
	zend_string *monospace_family;
	zend_string *languages;
	zend_string *font_files;
	zend_string *font_dirs;
	zend_string *resources_dir;
	zend_string *stylesheet;
	double dpi;
	double font_size;
	uint32_t width;
	uint32_t height;
	bool load_system_fonts;
	bool confine_resources;
	int32_t shape_rendering;
	int32_t text_rendering;
	int32_t image_rendering;
} resvg_ctor_options;

/* A reusable parse/render configuration owning the font database. The shim handle
 * is built once in the constructor; rebuilding it means re-scanning system fonts.
 *
 * `zend_object std` must sit at offset 0: create_object returns its address, and
 * the engine frees that exact pointer, so any field placed ahead of it makes every
 * object release an invalid free. Custom fields follow it. */
typedef struct _resvg_renderer_object {
	zend_object std;
	resvg_php_options *handle;
	/* Whether the caller set `resourcesDir` explicitly. The `*File()` methods
	 * resolve the file's own directory only when this is false, mirroring the
	 * CLI's `--resources-dir` precedence. */
	bool resources_dir_set;
} resvg_renderer_object;

/* A parsed document. Self-contained: it carries its own font database, so it may
 * outlive the renderer that produced it. */
typedef struct _resvg_tree_object {
	zend_object std;
	resvg_php_tree *handle;
} resvg_tree_object;

static zend_always_inline resvg_renderer_object *resvg_renderer_from_obj(zend_object *obj)
{
	return (resvg_renderer_object *)((char *)(obj)-XtOffsetOf(resvg_renderer_object, std));
}

static zend_always_inline resvg_tree_object *resvg_tree_from_obj(zend_object *obj)
{
	return (resvg_tree_object *)((char *)(obj)-XtOffsetOf(resvg_tree_object, std));
}

#define Z_RESVG_RENDERER_P(zv) resvg_renderer_from_obj(Z_OBJ_P(zv))
#define Z_RESVG_TREE_P(zv) resvg_tree_from_obj(Z_OBJ_P(zv))

extern zend_class_entry *resvg_renderer_ce;
extern zend_class_entry *resvg_tree_ce;
extern zend_class_entry *resvg_exception_ce;

zend_result resvg_register_renderer_class(void);
zend_result resvg_register_tree_class(void);
zend_result resvg_register_exception_class(void);

/* --- resvg_options.c: shared marshalling and delivery ------------------- */

void resvg_options_load_render(HashTable *options, uint32_t arg_index,
							   uint32_t *width, uint32_t *height, double *zoom, zend_string **background,
							   zend_string **output, int32_t *export_area);

/* Measure has its own surface: `output`/`background`/`exportArea` have no
 * meaning without a raster pass, so accepting them would be silent drift. */
void resvg_options_load_measure(HashTable *options, uint32_t arg_index, uint32_t *width,
								uint32_t *height, double *zoom);

void resvg_options_load_writer(HashTable *options, uint32_t arg_index,
							   int32_t *preserve_text, zend_string **id_prefix, int32_t *indent, int32_t *attrs_indent,
							   uint8_t *coordinates_precision, uint8_t *transforms_precision, int32_t *use_single_quote);

bool resvg_options_load_ctor(HashTable *options, uint32_t arg_index,
							 resvg_ctor_options *parsed, const struct resvg_hint *shape_hints, size_t shape_len,
							 const struct resvg_hint *text_hints, size_t text_len, const struct resvg_hint *image_hints,
							 size_t image_len);

/* Cross-field rule: confinement without a root is a caller error (the shim's
 * CWD fallback must stay unreachable from PHP). */
bool resvg_options_check_confine(const resvg_ctor_options *parsed, uint32_t arg_index);

void resvg_deliver_output(uint8_t *buffer, uintptr_t length, zend_string *output,
						  zval *return_value);

/* Reads a file for parsing. Returns NULL and leaves `*over_ceiling` false when
 * the file cannot be read; returns NULL with `*over_ceiling` true when it exists
 * but exceeds resvg.max_input_size, so the caller can report the ceiling rather
 * than a generic read failure. */
zend_string *resvg_read_file(zend_string *path, bool *over_ceiling);

/* The directory containing `path`, from its canonical form — the per-parse
 * `resourcesDir` the `*File()` methods supply when the caller set none. NULL
 * when the path cannot be canonicalized. */
zend_string *resvg_file_resources_dir(zend_string *path);

zend_long resvg_max_input_size(void);
zend_long resvg_max_render_pixels(void);

/* Raises Resvg\Exception from a shim status code, appending the shim's detail. */
void resvg_throw_status(int32_t status);

/* --- resvg_document.c: tree-backed render/measure/write, shared by both --- */

void resvg_tree_render_impl(resvg_php_tree *tree, HashTable *options, uint32_t arg_index,
							zval *return_value);
void resvg_tree_render_node_impl(resvg_php_tree *tree, zend_string *id, HashTable *options,
								 uint32_t arg_index, zval *return_value);
void resvg_tree_measure_impl(resvg_php_tree *tree, HashTable *options, uint32_t arg_index,
							 zval *return_value);
void resvg_tree_to_svg_impl(resvg_php_tree *tree, HashTable *options, uint32_t arg_index,
							zval *return_value);

/* Parses `bytes` into a new Resvg\Tree zval, throwing on failure.
 * `resources_dir` is the per-parse override, or NULL for the handle's own. */
void resvg_parse_into_zval(resvg_php_options *handle, zend_string *bytes,
						   zend_string *resources_dir, zval *return_value);

/* Parses `bytes`, returning a raw tree handle or NULL with an exception thrown. */
resvg_php_tree *resvg_tree_parse_or_throw(resvg_php_options *handle, zend_string *bytes,
										  zend_string *resources_dir);

#endif /* RESVG_INTERNAL_H */
