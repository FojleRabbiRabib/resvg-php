/*
 * resvg-php shim ABI — hand-written mirror of native/src/lib.rs.
 * Keep both sides in lockstep; the link step catches drift, the fidelity gate
 * catches semantic drift. SPDX-License-Identifier: Apache-2.0
 */

#ifndef RESVG_PHP_SHIM_H
#define RESVG_PHP_SHIM_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RspOptions resvg_php_options;
typedef struct RspTree resvg_php_tree;

/* Status codes — identical set to resvg_internal.h and the PHP constants. */
#define RSP_OK 0
#define RSP_ERROR_NULL_POINTER 1
#define RSP_ERROR_UTF8 2
#define RSP_ERROR_INVALID_SIZE 3
#define RSP_ERROR_PARSING 4
#define RSP_ERROR_ALLOCATION 5
#define RSP_ERROR_ENCODE 6
#define RSP_ERROR_INTERNAL 7
#define RSP_ERROR_INVALID_ARGUMENT 8
#define RSP_ERROR_NO_SUCH_NODE 9
#define RSP_ERROR_ZERO_SIZE_NODE 10
#define RSP_ERROR_ELEMENTS_LIMIT 11
#define RSP_ERROR_MALFORMED_GZIP 12
#define RSP_ERROR_SVGZ_DISABLED 13
#define RSP_ERROR_TOO_LARGE 14

/* Rendering-hint discriminants (usvg enum order). */
#define RSP_SHAPE_OPTIMIZE_SPEED 0
#define RSP_SHAPE_CRISP_EDGES 1
#define RSP_SHAPE_GEOMETRIC_PRECISION 2
#define RSP_TEXT_OPTIMIZE_SPEED 0
#define RSP_TEXT_OPTIMIZE_LEGIBILITY 1
#define RSP_TEXT_GEOMETRIC_PRECISION 2
#define RSP_IMAGE_OPTIMIZE_QUALITY 0
#define RSP_IMAGE_OPTIMIZE_SPEED 1
#define RSP_IMAGE_SMOOTH 2
#define RSP_IMAGE_HIGH_QUALITY 3
#define RSP_IMAGE_CRISP_EDGES 4
#define RSP_IMAGE_PIXELATED 5

/* Indent discriminants (xmlwriter::Indent); 0..=255 means that many spaces. */
#define RSP_INDENT_NONE (-1)
#define RSP_INDENT_TABS (-2)

/* Export-area modes, mirroring the CLI's --export-area-* flags. */
#define RSP_EXPORT_AREA_DRAWING 0
#define RSP_EXPORT_AREA_PAGE 1

resvg_php_options *resvg_php_options_create(
	const char *resources_dir,
	float dpi,
	const char *font_family,
	float font_size,
	const char *serif_family,
	const char *sans_serif_family,
	const char *cursive_family,
	const char *fantasy_family,
	const char *monospace_family,
	const char *languages,   /* comma-separated */
	const char *font_files,  /* newline-separated paths */
	const char *font_dirs,   /* newline-separated paths */
	int32_t load_system_fonts,
	int32_t shape_rendering,
	int32_t text_rendering,
	int32_t image_rendering,
	const char *stylesheet,
	int32_t confine_resources,
	uint32_t width, uint32_t height);

resvg_php_tree *resvg_php_tree_parse(
	const resvg_php_options *options, const uint8_t *data, uintptr_t len,
	const char *resources_dir, int32_t *out_status);

int32_t resvg_php_tree_size(const resvg_php_tree *tree, float *w, float *h);

int32_t resvg_php_tree_bbox(
	const resvg_php_tree *tree, float *x, float *y, float *w, float *h);

int32_t resvg_php_tree_measure(
	const resvg_php_tree *tree,
	uint32_t width, uint32_t height, float zoom,
	uint32_t *out_width, uint32_t *out_height);

bool resvg_php_tree_node_exists(const resvg_php_tree *tree, const char *id);

int32_t resvg_php_tree_node_ids(
	const resvg_php_tree *tree, uint8_t **out, uintptr_t *out_len);

int32_t resvg_php_tree_to_svg(
	const resvg_php_tree *tree,
	int32_t preserve_text, const char *id_prefix,
	int32_t indent, int32_t attrs_indent,
	uint8_t coordinates_precision, uint8_t transforms_precision,
	int32_t use_single_quote,
	uint8_t **out, uintptr_t *out_len);

int32_t resvg_php_tree_render(
	const resvg_php_tree *tree,
	uint32_t width, uint32_t height, float zoom,
	int32_t export_area, const char *background,
	uint64_t max_pixels,
	uint8_t **out, uintptr_t *out_len);

int32_t resvg_php_tree_render_node(
	const resvg_php_tree *tree, const char *id,
	uint32_t width, uint32_t height, float zoom,
	int32_t export_area, const char *background,
	uint64_t max_pixels,
	uint8_t **out, uintptr_t *out_len);

int32_t resvg_php_options_fonts(
	const resvg_php_options *options, uint8_t **out, uintptr_t *out_len);

void resvg_php_tree_free(resvg_php_tree *tree);

void resvg_php_options_free(resvg_php_options *options);

void resvg_php_free(uint8_t *ptr, uintptr_t len);

const char *resvg_php_last_error(void);

const char *resvg_php_version(void);

#ifdef __cplusplus
}
#endif

#endif /* RESVG_PHP_SHIM_H */
