/*
 * resvg-php — Resvg\Tree: the parsed document object, plus the tree-backed
 * render/measure/toSvg implementations shared with the renderer's convenience path.
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "php.h"
#include "Zend/zend_exceptions.h"
#include "php_resvg.h"
#include "resvg_arginfo.h"
#include "resvg_internal.h"

zend_class_entry *resvg_tree_ce = NULL;
static zend_object_handlers resvg_tree_handlers;

static void resvg_tree_free_storage(zend_object *object)
{
	resvg_tree_object *tree = resvg_tree_from_obj(object);

	if (tree->handle != NULL) {
		resvg_php_tree_free(tree->handle);
		tree->handle = NULL;
	}

	zend_object_std_dtor(object);
}

static zend_object *resvg_tree_create_object(zend_class_entry *ce)
{
	/* zend_object_properties_size() subtracts the implicit property slot
	 * unconditionally, so it underflows to (size_t)-16 for a class that declares
	 * none — wrapping the allocation below by exactly that slot and leaving the
	 * object's own zend_object std overflowing the block. Sizing from the declared
	 * count directly keeps it whole. */
	resvg_tree_object *wrapper =
		ecalloc(1, sizeof(resvg_tree_object) + sizeof(zval) * ce->default_properties_count);

	zend_object_std_init(&wrapper->std, ce);
	object_properties_init(&wrapper->std, ce);
	wrapper->std.handlers = &resvg_tree_handlers;

	return &wrapper->std;
}

/* --- shared implementations ---------------------------------------------- */

resvg_php_tree *resvg_tree_parse_or_throw(resvg_php_options *handle, zend_string *bytes,
										  zend_string *resources_dir)
{
	zend_long ceiling = resvg_max_input_size();
	if (ceiling > 0 && ZSTR_LEN(bytes) > (size_t)ceiling) {
		zend_throw_exception(resvg_exception_ce,
							 "The SVG document exceeds resvg.max_input_size", 0);
		return NULL;
	}

	int32_t status = RESVG_STATUS_OK;
	resvg_php_tree *tree = resvg_php_tree_parse(
		handle, (const uint8_t *)ZSTR_VAL(bytes), ZSTR_LEN(bytes),
		resources_dir != NULL ? ZSTR_VAL(resources_dir) : NULL, &status);

	if (tree == NULL) {
		resvg_throw_status(status == RESVG_STATUS_OK ? RESVG_STATUS_INTERNAL : status);
		return NULL;
	}

	return tree;
}

void resvg_parse_into_zval(resvg_php_options *handle, zend_string *bytes,
						   zend_string *resources_dir, zval *return_value)
{
	resvg_php_tree *tree = resvg_tree_parse_or_throw(handle, bytes, resources_dir);

	if (tree == NULL) {
		RETURN_THROWS();
	}

	object_init_ex(return_value, resvg_tree_ce);
	Z_RESVG_TREE_P(return_value)->handle = tree;
}

/* The pixel ceiling is enforced by the shim on the *produced* size — after
 * fit-to has resolved it — so zoom, single-side fit, default-size and node
 * exports are all bounded. A C-side pre-check here could not know that size. */
static uint64_t resvg_render_pixel_ceiling(void)
{
	zend_long ceiling = resvg_max_render_pixels();

	return ceiling > 0 ? (uint64_t)ceiling : 0;
}

static void resvg_write_png_to_sink(uint8_t *png, uintptr_t length, zval *sink, zval *return_value)
{
	php_stream *stream = NULL;
	php_stream_from_zval_no_verify(stream, sink);
	if (stream == NULL) {
		resvg_php_free(png, length);
		zend_throw_exception(resvg_exception_ce, "The output sink is not a writable stream", 0);
		RETURN_THROWS();
	}
	size_t written = php_stream_write(stream, (const char *)png, (size_t)length);
	resvg_php_free(png, length);
	if (written != (size_t)length) {
		zend_throw_exception(resvg_exception_ce, "Failed to write the full PNG to the output sink",
							 0);
		RETURN_THROWS();
	}
	/* Sink delivery returns true: the caller asked for the bytes to go to the
	 * stream, and shipping a second full copy back as the return value is what
	 * the option exists to avoid. */
	ZVAL_TRUE(return_value);
}

static void resvg_deliver_png(uint8_t *png, uintptr_t length, zend_string *output,
							  HashTable *options, zval *return_value)
{
	if (output == NULL && options != NULL) {
		zval *sink = zend_hash_str_find(options, "output", sizeof("output") - 1);
		if (sink != NULL && Z_TYPE_P(sink) == IS_RESOURCE) {
			resvg_write_png_to_sink(png, length, sink, return_value);
			return;
		}
	}

	resvg_deliver_output(png, length, output, return_value);
}

void resvg_tree_render_impl(resvg_php_tree *tree, HashTable *options, uint32_t arg_index,
							zval *return_value)
{
	uint32_t width = 0;
	uint32_t height = 0;
	double zoom = 0.0;
	zend_string *background = NULL;
	zend_string *output = NULL;
	int32_t export_area = RSP_EXPORT_AREA_DRAWING;

	resvg_options_load_render(options, arg_index, &width, &height, &zoom, &background,
							  &output, &export_area);
	if (EG(exception)) {
		RETURN_THROWS();
	}

	uint8_t *png = NULL;
	uintptr_t length = 0;
	int32_t status =
		resvg_php_tree_render(tree, width, height, (float)zoom, export_area,
							  background != NULL ? ZSTR_VAL(background) : NULL,
							  resvg_render_pixel_ceiling(), &png, &length);

	if (status != RESVG_STATUS_OK) {
		resvg_throw_status(status);
		RETURN_THROWS();
	}

	resvg_deliver_png(png, length, output, options, return_value);
}

void resvg_tree_render_node_impl(resvg_php_tree *tree, zend_string *id, HashTable *options,
								 uint32_t arg_index, zval *return_value)
{
	uint32_t width = 0;
	uint32_t height = 0;
	double zoom = 0.0;
	zend_string *background = NULL;
	zend_string *output = NULL;
	int32_t export_area = RSP_EXPORT_AREA_DRAWING;

	resvg_options_load_render(options, arg_index, &width, &height, &zoom, &background,
							  &output, &export_area);
	if (EG(exception)) {
		RETURN_THROWS();
	}

	uint8_t *png = NULL;
	uintptr_t length = 0;
	int32_t status =
		resvg_php_tree_render_node(tree, ZSTR_VAL(id), width, height, (float)zoom, export_area,
								   background != NULL ? ZSTR_VAL(background) : NULL,
								   resvg_render_pixel_ceiling(), &png, &length);

	if (status != RESVG_STATUS_OK) {
		resvg_throw_status(status);
		RETURN_THROWS();
	}

	resvg_deliver_png(png, length, output, options, return_value);
}

void resvg_tree_measure_impl(resvg_php_tree *tree, HashTable *options, uint32_t arg_index,
							 zval *return_value)
{
	uint32_t width = 0;
	uint32_t height = 0;
	double zoom = 0.0;

	resvg_options_load_measure(options, arg_index, &width, &height, &zoom);
	if (EG(exception)) {
		RETURN_THROWS();
	}

	uint32_t out_w = 0;
	uint32_t out_h = 0;
	int32_t status =
		resvg_php_tree_measure(tree, width, height, (float)zoom, &out_w, &out_h);
	if (status != RESVG_STATUS_OK) {
		resvg_throw_status(status);
		RETURN_THROWS();
	}

	array_init(return_value);
	add_assoc_long(return_value, "width", (zend_long)out_w);
	add_assoc_long(return_value, "height", (zend_long)out_h);
}

void resvg_tree_to_svg_impl(resvg_php_tree *tree, HashTable *options, uint32_t arg_index,
							zval *return_value)
{
	int32_t preserve_text = 0;
	zend_string *id_prefix = NULL;
	int32_t indent = 4;
	int32_t attrs_indent = RSP_INDENT_NONE;
	uint8_t coordinates_precision = 8;
	uint8_t transforms_precision = 8;
	int32_t use_single_quote = 0;

	resvg_options_load_writer(options, arg_index, &preserve_text, &id_prefix, &indent,
							  &attrs_indent, &coordinates_precision, &transforms_precision, &use_single_quote);
	if (EG(exception)) {
		RETURN_THROWS();
	}

	uint8_t *svg = NULL;
	uintptr_t length = 0;
	int32_t status = resvg_php_tree_to_svg(tree, preserve_text,
										   id_prefix != NULL ? ZSTR_VAL(id_prefix) : NULL, indent, attrs_indent,
										   coordinates_precision, transforms_precision, use_single_quote, &svg, &length);

	if (status != RESVG_STATUS_OK) {
		resvg_throw_status(status);
		RETURN_THROWS();
	}

	ZVAL_STRINGL(return_value, (const char *)svg, (size_t)length);
	resvg_php_free(svg, length);
}

/* --- Resvg\Tree methods --------------------------------------------------- */

/* Private: a Tree is produced by the renderer, never constructed in userland.
 * A user-created instance would carry a NULL handle into every method. */
PHP_METHOD(Resvg_Tree, __construct)
{
	ZEND_PARSE_PARAMETERS_NONE();

	zend_throw_exception(resvg_exception_ce,
						 "Tree objects are created by Renderer::parse(), not constructed", 0);
	RETURN_THROWS();
}

PHP_METHOD(Resvg_Tree, size)
{
	ZEND_PARSE_PARAMETERS_NONE();

	resvg_tree_object *wrapper = Z_RESVG_TREE_P(ZEND_THIS);
	if (wrapper->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Tree is not initialized", 0);
		RETURN_THROWS();
	}

	float w = 0.0f;
	float h = 0.0f;
	int32_t status = resvg_php_tree_size(wrapper->handle, &w, &h);
	if (status != RESVG_STATUS_OK) {
		resvg_throw_status(status);
		RETURN_THROWS();
	}

	array_init(return_value);
	add_assoc_double(return_value, "width", (double)w);
	add_assoc_double(return_value, "height", (double)h);
}

PHP_METHOD(Resvg_Tree, boundingBox)
{
	ZEND_PARSE_PARAMETERS_NONE();

	resvg_tree_object *wrapper = Z_RESVG_TREE_P(ZEND_THIS);
	if (wrapper->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Tree is not initialized", 0);
		RETURN_THROWS();
	}

	float x = 0.0f;
	float y = 0.0f;
	float w = 0.0f;
	float h = 0.0f;
	int32_t status = resvg_php_tree_bbox(wrapper->handle, &x, &y, &w, &h);

	if (status == RESVG_STATUS_ZERO_SIZE_NODE) {
		RETURN_NULL();
	}
	if (status != RESVG_STATUS_OK) {
		resvg_throw_status(status);
		RETURN_THROWS();
	}

	array_init(return_value);
	add_assoc_double(return_value, "x", (double)x);
	add_assoc_double(return_value, "y", (double)y);
	add_assoc_double(return_value, "width", (double)w);
	add_assoc_double(return_value, "height", (double)h);
}

PHP_METHOD(Resvg_Tree, hasNode)
{
	zend_string *id;

	ZEND_PARSE_PARAMETERS_START(1, 1)
	Z_PARAM_STR(id)
	ZEND_PARSE_PARAMETERS_END();

	resvg_tree_object *wrapper = Z_RESVG_TREE_P(ZEND_THIS);
	if (wrapper->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Tree is not initialized", 0);
		RETURN_THROWS();
	}

	RETURN_BOOL(resvg_php_tree_node_exists(wrapper->handle, ZSTR_VAL(id)));
}

PHP_METHOD(Resvg_Tree, nodeIds)
{
	ZEND_PARSE_PARAMETERS_NONE();

	resvg_tree_object *wrapper = Z_RESVG_TREE_P(ZEND_THIS);
	if (wrapper->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Tree is not initialized", 0);
		RETURN_THROWS();
	}

	uint8_t *buffer = NULL;
	uintptr_t length = 0;
	int32_t status = resvg_php_tree_node_ids(wrapper->handle, &buffer, &length);
	if (status != RESVG_STATUS_OK) {
		resvg_throw_status(status);
		RETURN_THROWS();
	}

	array_init(return_value);
	if (length == 0) {
		resvg_php_free(buffer, length);
		return;
	}

	zend_string *joined = zend_string_init((const char *)buffer, (size_t)length, 0);
	resvg_php_free(buffer, length);

	/* The shim joins ids with NUL: usvg does not enforce XML `Name` on the id
	 * attribute, so an id may legally contain a newline and a newline-joined
	 * list could not be split back unambiguously. */
	const char *cursor = ZSTR_VAL(joined);
	const char *end = cursor + ZSTR_LEN(joined);
	while (cursor < end) {
		const char *nul = memchr(cursor, '\0', (size_t)(end - cursor));
		size_t part_len = nul != NULL ? (size_t)(nul - cursor) : (size_t)(end - cursor);

		add_next_index_stringl(return_value, cursor, part_len);

		if (nul == NULL) {
			break;
		}
		cursor = nul + 1;
	}
	zend_string_release(joined);
}

PHP_METHOD(Resvg_Tree, render)
{
	HashTable *options = NULL;

	ZEND_PARSE_PARAMETERS_START(0, 1)
	Z_PARAM_OPTIONAL
	Z_PARAM_ARRAY_HT(options)
	ZEND_PARSE_PARAMETERS_END();

	resvg_tree_object *wrapper = Z_RESVG_TREE_P(ZEND_THIS);
	if (wrapper->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Tree is not initialized", 0);
		RETURN_THROWS();
	}

	resvg_tree_render_impl(wrapper->handle, options, 1, return_value);
}

PHP_METHOD(Resvg_Tree, renderNode)
{
	zend_string *id;
	HashTable *options = NULL;

	ZEND_PARSE_PARAMETERS_START(1, 2)
	Z_PARAM_STR(id)
	Z_PARAM_OPTIONAL
	Z_PARAM_ARRAY_HT(options)
	ZEND_PARSE_PARAMETERS_END();

	resvg_tree_object *wrapper = Z_RESVG_TREE_P(ZEND_THIS);
	if (wrapper->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Tree is not initialized", 0);
		RETURN_THROWS();
	}

	resvg_tree_render_node_impl(wrapper->handle, id, options, 2, return_value);
}

PHP_METHOD(Resvg_Tree, toSvg)
{
	HashTable *options = NULL;

	ZEND_PARSE_PARAMETERS_START(0, 1)
	Z_PARAM_OPTIONAL
	Z_PARAM_ARRAY_HT(options)
	ZEND_PARSE_PARAMETERS_END();

	resvg_tree_to_svg_impl(Z_RESVG_TREE_P(ZEND_THIS)->handle, options, 1, return_value);
}

static const zend_function_entry resvg_tree_methods[] = {
	PHP_ME(Resvg_Tree, __construct, arginfo_class_Resvg_Tree___construct, ZEND_ACC_PRIVATE)
		PHP_ME(Resvg_Tree, size, arginfo_class_Resvg_Tree_size, ZEND_ACC_PUBLIC)
			PHP_ME(Resvg_Tree, boundingBox, arginfo_class_Resvg_Tree_boundingBox, ZEND_ACC_PUBLIC)
				PHP_ME(Resvg_Tree, hasNode, arginfo_class_Resvg_Tree_hasNode, ZEND_ACC_PUBLIC)
					PHP_ME(Resvg_Tree, nodeIds, arginfo_class_Resvg_Tree_nodeIds, ZEND_ACC_PUBLIC)
						PHP_ME(Resvg_Tree, render, arginfo_class_Resvg_Tree_render, ZEND_ACC_PUBLIC)
							PHP_ME(Resvg_Tree, renderNode, arginfo_class_Resvg_Tree_renderNode,
								   ZEND_ACC_PUBLIC)
								PHP_ME(Resvg_Tree, toSvg, arginfo_class_Resvg_Tree_toSvg,
									   ZEND_ACC_PUBLIC)
									PHP_FE_END};

zend_result resvg_register_tree_class(void)
{
	zend_class_entry ce;

	INIT_NS_CLASS_ENTRY(ce, "Resvg", "Tree", resvg_tree_methods);
	resvg_tree_ce = zend_register_internal_class(&ce);
	if (resvg_tree_ce == NULL) {
		return FAILURE;
	}
	resvg_tree_ce->ce_flags |= ZEND_ACC_FINAL;
	resvg_tree_ce->create_object = resvg_tree_create_object;

	memcpy(&resvg_tree_handlers, &std_object_handlers, sizeof(zend_object_handlers));
	resvg_tree_handlers.free_obj = resvg_tree_free_storage;
	resvg_tree_handlers.clone_obj = NULL;

	return SUCCESS;
}
