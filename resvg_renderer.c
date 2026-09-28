/*
 * resvg-php — Resvg\Renderer: configuration, parsing, and the convenience render path.
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

zend_class_entry *resvg_renderer_ce = NULL;
static zend_object_handlers resvg_renderer_handlers;

static void resvg_renderer_free_storage(zend_object *object)
{
	resvg_renderer_object *renderer = resvg_renderer_from_obj(object);

	if (renderer->handle != NULL) {
		resvg_php_options_free(renderer->handle);
		renderer->handle = NULL;
	}

	zend_object_std_dtor(object);
}

static zend_object *resvg_renderer_create_object(zend_class_entry *ce)
{
	/* Same sizing rule as the tree object: see the note in resvg_document.c. */
	resvg_renderer_object *renderer =
		ecalloc(1, sizeof(resvg_renderer_object) + sizeof(zval) * ce->default_properties_count);

	zend_object_std_init(&renderer->std, ce);
	object_properties_init(&renderer->std, ce);
	renderer->std.handlers = &resvg_renderer_handlers;

	return &renderer->std;
}

PHP_METHOD(Resvg_Renderer, __construct)
{
	HashTable *options = NULL;

	ZEND_PARSE_PARAMETERS_START(0, 1)
	Z_PARAM_OPTIONAL
	Z_PARAM_ARRAY_HT(options)
	ZEND_PARSE_PARAMETERS_END();

	static const struct resvg_hint shape_hints[] = {
		{"optimizeSpeed", RSP_SHAPE_OPTIMIZE_SPEED},
		{"crispEdges", RSP_SHAPE_CRISP_EDGES},
		{"geometricPrecision", RSP_SHAPE_GEOMETRIC_PRECISION},
	};
	static const struct resvg_hint text_hints[] = {
		{"optimizeSpeed", RSP_TEXT_OPTIMIZE_SPEED},
		{"optimizeLegibility", RSP_TEXT_OPTIMIZE_LEGIBILITY},
		{"geometricPrecision", RSP_TEXT_GEOMETRIC_PRECISION},
	};
	static const struct resvg_hint image_hints[] = {
		{"optimizeQuality", RSP_IMAGE_OPTIMIZE_QUALITY},
		{"optimizeSpeed", RSP_IMAGE_OPTIMIZE_SPEED},
		{"smooth", RSP_IMAGE_SMOOTH},
		{"high-quality", RSP_IMAGE_HIGH_QUALITY},
		{"crisp-edges", RSP_IMAGE_CRISP_EDGES},
		{"pixelated", RSP_IMAGE_PIXELATED},
	};

	resvg_renderer_object *renderer = Z_RESVG_RENDERER_P(ZEND_THIS);
	resvg_ctor_options parsed;

	if (!resvg_options_load_ctor(options, 1, &parsed, shape_hints,
								 sizeof(shape_hints) / sizeof(shape_hints[0]), text_hints,
								 sizeof(text_hints) / sizeof(text_hints[0]), image_hints,
								 sizeof(image_hints) / sizeof(image_hints[0]))) {
		RETURN_THROWS();
	}
	if (!resvg_options_check_confine(&parsed, 1)) {
		RETURN_THROWS();
	}

	/* Constructors are re-callable from PHP; dropping the old handle here is
	 * what keeps `$r->__construct()` from leaking a font database per call. */
	if (renderer->handle != NULL) {
		resvg_php_options_free(renderer->handle);
		renderer->handle = NULL;
	}
	renderer->resources_dir_set = parsed.resources_dir != NULL;

	renderer->handle = resvg_php_options_create(
		parsed.resources_dir != NULL ? ZSTR_VAL(parsed.resources_dir) : NULL,
		(float)parsed.dpi,
		parsed.font_family != NULL ? ZSTR_VAL(parsed.font_family) : NULL,
		(float)parsed.font_size,
		parsed.serif_family != NULL ? ZSTR_VAL(parsed.serif_family) : NULL,
		parsed.sans_serif_family != NULL ? ZSTR_VAL(parsed.sans_serif_family) : NULL,
		parsed.cursive_family != NULL ? ZSTR_VAL(parsed.cursive_family) : NULL,
		parsed.fantasy_family != NULL ? ZSTR_VAL(parsed.fantasy_family) : NULL,
		parsed.monospace_family != NULL ? ZSTR_VAL(parsed.monospace_family) : NULL,
		parsed.languages != NULL ? ZSTR_VAL(parsed.languages) : NULL,
		parsed.font_files != NULL ? ZSTR_VAL(parsed.font_files) : NULL,
		parsed.font_dirs != NULL ? ZSTR_VAL(parsed.font_dirs) : NULL,
		parsed.load_system_fonts ? 1 : 0, parsed.shape_rendering, parsed.text_rendering,
		parsed.image_rendering,
		parsed.stylesheet != NULL ? ZSTR_VAL(parsed.stylesheet) : NULL,
		parsed.confine_resources ? 1 : 0, parsed.width, parsed.height);

	if (renderer->handle == NULL) {
		zend_throw_exception(resvg_exception_ce,
							 "Failed to initialize the render configuration", 0);
		RETURN_THROWS();
	}
}

PHP_METHOD(Resvg_Renderer, parse)
{
	zend_string *svg;

	ZEND_PARSE_PARAMETERS_START(1, 1)
	Z_PARAM_STR(svg)
	ZEND_PARSE_PARAMETERS_END();

	resvg_parse_into_zval(Z_RESVG_RENDERER_P(ZEND_THIS)->handle, svg, NULL, return_value);
}

/* Reads a file for the `*File()` methods, reporting the failure precisely: an
 * oversized document names its ceiling, anything else is a read failure. */
static zend_string *resvg_read_file_or_throw(zend_string *path)
{
	bool over_ceiling = false;
	zend_string *bytes = resvg_read_file(path, &over_ceiling);

	if (bytes == NULL && !over_ceiling) {
		zend_throw_exception(resvg_exception_ce, "Cannot read the SVG file", 0);
	} else if (over_ceiling) {
		zend_throw_exception(resvg_exception_ce,
							 "The SVG document exceeds resvg.max_input_size", 0);
	}

	return bytes;
}

PHP_METHOD(Resvg_Renderer, parseFile)
{
	zend_string *path;

	ZEND_PARSE_PARAMETERS_START(1, 1)
	Z_PARAM_STR(path)
	ZEND_PARSE_PARAMETERS_END();

	resvg_renderer_object *renderer = Z_RESVG_RENDERER_P(ZEND_THIS);
	zend_string *bytes = resvg_read_file_or_throw(path);
	if (bytes == NULL) {
		RETURN_THROWS();
	}

	/* Relative hrefs resolve against the file's own directory, as the CLI does,
	 * unless the caller named a resourcesDir explicitly. */
	zend_string *dir = renderer->resources_dir_set ? NULL : resvg_file_resources_dir(path);
	resvg_parse_into_zval(renderer->handle, bytes, dir, return_value);
	zend_string_release(bytes);
	if (dir != NULL) {
		zend_string_release(dir);
	}
}

PHP_METHOD(Resvg_Renderer, render)
{
	zend_string *svg;
	HashTable *options = NULL;

	ZEND_PARSE_PARAMETERS_START(1, 2)
	Z_PARAM_STR(svg)
	Z_PARAM_OPTIONAL
	Z_PARAM_ARRAY_HT(options)
	ZEND_PARSE_PARAMETERS_END();

	resvg_renderer_object *renderer = Z_RESVG_RENDERER_P(ZEND_THIS);
	if (renderer->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Renderer is not initialized", 0);
		RETURN_THROWS();
	}

	resvg_php_tree *tree = resvg_tree_parse_or_throw(renderer->handle, svg, NULL);
	if (tree == NULL) {
		RETURN_THROWS();
	}
	resvg_tree_render_impl(tree, options, 2, return_value);
	resvg_php_tree_free(tree);
}

PHP_METHOD(Resvg_Renderer, renderFile)
{
	zend_string *path;
	HashTable *options = NULL;

	ZEND_PARSE_PARAMETERS_START(1, 2)
	Z_PARAM_STR(path)
	Z_PARAM_OPTIONAL
	Z_PARAM_ARRAY_HT(options)
	ZEND_PARSE_PARAMETERS_END();

	resvg_renderer_object *renderer = Z_RESVG_RENDERER_P(ZEND_THIS);
	if (renderer->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Renderer is not initialized", 0);
		RETURN_THROWS();
	}

	zend_string *bytes = resvg_read_file_or_throw(path);
	if (bytes == NULL) {
		RETURN_THROWS();
	}
	zend_string *dir = renderer->resources_dir_set ? NULL : resvg_file_resources_dir(path);

	resvg_php_tree *tree = resvg_tree_parse_or_throw(renderer->handle, bytes, dir);
	zend_string_release(bytes);
	zend_string_release(dir);
	if (tree == NULL) {
		RETURN_THROWS();
	}
	resvg_tree_render_impl(tree, options, 2, return_value);
	resvg_php_tree_free(tree);
}

PHP_METHOD(Resvg_Renderer, measure)
{
	zend_string *svg;
	HashTable *options = NULL;

	ZEND_PARSE_PARAMETERS_START(1, 2)
	Z_PARAM_STR(svg)
	Z_PARAM_OPTIONAL
	Z_PARAM_ARRAY_HT(options)
	ZEND_PARSE_PARAMETERS_END();

	resvg_renderer_object *renderer = Z_RESVG_RENDERER_P(ZEND_THIS);
	if (renderer->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Renderer is not initialized", 0);
		RETURN_THROWS();
	}

	resvg_php_tree *tree = resvg_tree_parse_or_throw(renderer->handle, svg, NULL);
	if (tree == NULL) {
		RETURN_THROWS();
	}
	resvg_tree_measure_impl(tree, options, 2, return_value);
	resvg_php_tree_free(tree);
}

PHP_METHOD(Resvg_Renderer, measureFile)
{
	zend_string *path;
	HashTable *options = NULL;

	ZEND_PARSE_PARAMETERS_START(1, 2)
	Z_PARAM_STR(path)
	Z_PARAM_OPTIONAL
	Z_PARAM_ARRAY_HT(options)
	ZEND_PARSE_PARAMETERS_END();

	resvg_renderer_object *renderer = Z_RESVG_RENDERER_P(ZEND_THIS);
	if (renderer->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Renderer is not initialized", 0);
		RETURN_THROWS();
	}

	zend_string *bytes = resvg_read_file_or_throw(path);
	if (bytes == NULL) {
		RETURN_THROWS();
	}
	zend_string *dir = renderer->resources_dir_set ? NULL : resvg_file_resources_dir(path);

	resvg_php_tree *tree = resvg_tree_parse_or_throw(renderer->handle, bytes, dir);
	zend_string_release(bytes);
	zend_string_release(dir);
	if (tree == NULL) {
		RETURN_THROWS();
	}
	resvg_tree_measure_impl(tree, options, 2, return_value);
	resvg_php_tree_free(tree);
}

PHP_METHOD(Resvg_Renderer, fonts)
{
	ZEND_PARSE_PARAMETERS_NONE();

	resvg_renderer_object *renderer = Z_RESVG_RENDERER_P(ZEND_THIS);
	if (renderer->handle == NULL) {
		zend_throw_exception(resvg_exception_ce, "Renderer is not initialized", 0);
		RETURN_THROWS();
	}

	uint8_t *buffer = NULL;
	uintptr_t length = 0;
	int32_t status = resvg_php_options_fonts(renderer->handle, &buffer, &length);
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

	const char *cursor = ZSTR_VAL(joined);
	const char *end = cursor + ZSTR_LEN(joined);
	while (cursor < end) {
		const char *newline = memchr(cursor, '\n', (size_t)(end - cursor));
		size_t row_len = newline != NULL ? (size_t)(newline - cursor) : (size_t)(end - cursor);

		/* Each row is "family\tpath\tstatus". The status is split off the *last*
		 * tab so a path containing a tab survives, and the family off the first;
		 * the status column is real: a failed load reports `failed` rather than
		 * being indistinguishable from a success. */
		const char *status_tab = NULL;
		for (size_t i = row_len; i > 0; i--) {
			if (cursor[i - 1] == '\t') {
				status_tab = cursor + i - 1;
				break;
			}
		}
		const char *family_tab = status_tab != NULL ? memchr(cursor, '\t', row_len) : NULL;

		if (status_tab != NULL && family_tab != NULL && family_tab != status_tab) {
			zend_string *family = zend_string_init(cursor, (size_t)(family_tab - cursor), 0);
			const char *path = family_tab + 1;
			size_t path_len = (size_t)(status_tab - path);
			const char *status = status_tab + 1;
			size_t status_len = row_len - (size_t)(status - cursor);

			if (status_len == 6 && memcmp(status, "failed", 6) == 0) {
				/* Warn-and-continue, matching upstream's font load diagnostics;
				 * the failed path loaded no face, so it is not in the map. */
				php_error_docref(NULL, E_USER_WARNING, "Failed to load font '%.*s'",
								 (int)path_len, path);
			} else {
				zval path_zv;
				ZVAL_STR(&path_zv, zend_string_init(path, path_len, 0));
				zend_symtable_update(Z_ARRVAL_P(return_value), family, &path_zv);
			}
			zend_string_release(family);
		}

		if (newline == NULL) {
			break;
		}
		cursor = newline + 1;
	}
	zend_string_release(joined);
}

PHP_METHOD(Resvg_Renderer, version)
{
	ZEND_PARSE_PARAMETERS_NONE();

	RETURN_STRING(resvg_php_version());
}

static const zend_function_entry resvg_renderer_methods[] = {
	PHP_ME(Resvg_Renderer, __construct, arginfo_class_Resvg_Renderer___construct,
		   ZEND_ACC_PUBLIC)
		PHP_ME(Resvg_Renderer, parse, arginfo_class_Resvg_Renderer_parse, ZEND_ACC_PUBLIC)
			PHP_ME(Resvg_Renderer, parseFile, arginfo_class_Resvg_Renderer_parseFile, ZEND_ACC_PUBLIC)
				PHP_ME(Resvg_Renderer, render, arginfo_class_Resvg_Renderer_render, ZEND_ACC_PUBLIC)
					PHP_ME(Resvg_Renderer, renderFile, arginfo_class_Resvg_Renderer_renderFile, ZEND_ACC_PUBLIC)
						PHP_ME(Resvg_Renderer, measure, arginfo_class_Resvg_Renderer_measure, ZEND_ACC_PUBLIC)
							PHP_ME(Resvg_Renderer, measureFile, arginfo_class_Resvg_Renderer_measureFile,
								   ZEND_ACC_PUBLIC)
								PHP_ME(Resvg_Renderer, fonts, arginfo_class_Resvg_Renderer_fonts, ZEND_ACC_PUBLIC)
									PHP_ME(Resvg_Renderer, version, arginfo_class_Resvg_Renderer_version,
										   ZEND_ACC_PUBLIC | ZEND_ACC_STATIC)
										PHP_FE_END};

zend_result resvg_register_renderer_class(void)
{
	zend_class_entry ce;

	INIT_NS_CLASS_ENTRY(ce, "Resvg", "Renderer", resvg_renderer_methods);
	resvg_renderer_ce = zend_register_internal_class(&ce);
	if (resvg_renderer_ce == NULL) {
		return FAILURE;
	}
	resvg_renderer_ce->ce_flags |= ZEND_ACC_FINAL;
	resvg_renderer_ce->create_object = resvg_renderer_create_object;

	memcpy(&resvg_renderer_handlers, &std_object_handlers, sizeof(zend_object_handlers));
	resvg_renderer_handlers.free_obj = resvg_renderer_free_storage;
	resvg_renderer_handlers.clone_obj = NULL;

	return SUCCESS;
}
