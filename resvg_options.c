/*
 * resvg-php — shared option-array marshalling, output delivery, and ceilings.
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "php.h"
#include "ext/spl/spl_exceptions.h"
#include "Zend/zend_exceptions.h"
#include "Zend/zend_smart_str.h"
#include "php_resvg.h"
#include "resvg_internal.h"

zend_long resvg_max_input_size(void)
{
	return RESVG_G(max_input_size);
}

zend_long resvg_max_render_pixels(void)
{
	return RESVG_G(max_render_pixels);
}

void resvg_throw_status(int32_t status)
{
	const char *message;
	const char *detail = resvg_php_last_error();

	switch (status) {
	case RESVG_STATUS_UTF8:
		message = "SVG input is not valid UTF-8";
		break;
	case RESVG_STATUS_INVALID_SIZE:
		message = "SVG has no valid size";
		break;
	case RESVG_STATUS_PARSING:
		message = "Failed to parse the SVG document";
		break;
	case RESVG_STATUS_ALLOCATION:
		message = "Renderer could not allocate the raster surface";
		break;
	case RESVG_STATUS_ENCODE:
		message = "Failed to encode the PNG output";
		break;
	case RESVG_STATUS_INVALID_ARGUMENT:
		message = "Invalid render option value";
		break;
	case RESVG_STATUS_NO_SUCH_NODE:
		message = "No node with the given id exists in the document";
		break;
	case RESVG_STATUS_ZERO_SIZE_NODE:
		message = "The requested node has a zero-size bounding box";
		break;
	case RESVG_STATUS_ELEMENTS_LIMIT:
		message = "The document exceeds the 1000000-element limit";
		break;
	case RESVG_STATUS_MALFORMED_GZIP:
		message = "SVGZ input is not a valid gzip stream";
		break;
	case RESVG_STATUS_SVGZ_DISABLED:
		message = "SVGZ support is not compiled into this build";
		break;
	case RESVG_STATUS_TOO_LARGE:
		message = "The requested render size exceeds resvg.max_render_pixels";
		break;
	case RESVG_STATUS_NULL_POINTER:
	case RESVG_STATUS_INTERNAL:
	default:
		message = "Internal renderer failure was contained";
		break;
	}

	/* The parser's own detail is appended when the shim supplied one, so a
	 * malformed document reports where it failed rather than only that it did. */
	if (detail != NULL && detail[0] != '\0') {
		zend_string *full = strpprintf(0, "%s: %s", message, detail);
		zend_throw_exception(resvg_exception_ce, ZSTR_VAL(full), (zend_long)status);
		zend_string_release(full);
		return;
	}

	zend_throw_exception(resvg_exception_ce, message, (zend_long)status);
}

/* ------------------------------------------------------------------------- */
/* Option marshalling                                                        */
/* ------------------------------------------------------------------------- */

static zval *resvg_option_find(HashTable *options, const char *key)
{
	if (options == NULL) {
		return NULL;
	}
	return zend_hash_str_find(options, key, strlen(key));
}

/* Unknown keys are rejected rather than ignored: a typo silently changing render
 * behaviour is exactly the class of bug the fidelity gate cannot catch. */
static bool resvg_options_reject_unknown(HashTable *options, uint32_t arg_index,
										 const char *const *allowed, size_t count)
{
	if (options == NULL) {
		return true;
	}

	zend_string *key;
	zend_ulong index;

	ZEND_HASH_FOREACH_KEY(options, index, key)
	{
		(void)index;
		if (key == NULL) {
			zend_argument_value_error(arg_index, "option keys must be strings");
			return false;
		}
		bool known = false;
		for (size_t i = 0; i < count; i++) {
			if (zend_string_equals_cstr(key, allowed[i], strlen(allowed[i]))) {
				known = true;
				break;
			}
		}
		if (!known) {
			zend_argument_value_error(arg_index, "unknown option \"%s\"", ZSTR_VAL(key));
			return false;
		}
	}
	ZEND_HASH_FOREACH_END();

	return true;
}

static bool resvg_option_uint32(HashTable *options, uint32_t arg_index, const char *key,
								uint32_t *value)
{
	zval *entry = resvg_option_find(options, key);

	if (entry == NULL) {
		return true;
	}
	if (Z_TYPE_P(entry) != IS_LONG || Z_LVAL_P(entry) < 0 || Z_LVAL_P(entry) > UINT32_MAX) {
		zend_argument_value_error(arg_index, "\"%s\" must be a non-negative int", key);
		return false;
	}
	*value = (uint32_t)Z_LVAL_P(entry);

	return true;
}

static bool resvg_option_double(HashTable *options, uint32_t arg_index, const char *key,
								double *value)
{
	zval *entry = resvg_option_find(options, key);

	if (entry == NULL) {
		return true;
	}
	if (Z_TYPE_P(entry) != IS_LONG && Z_TYPE_P(entry) != IS_DOUBLE) {
		zend_argument_value_error(arg_index, "\"%s\" must be of type float", key);
		return false;
	}
	*value = zval_get_double(entry);

	return true;
}

/* A double option constrained to a closed range, mirroring the CLI's own bounds
 * (`crates/resvg/src/main.rs` parse_dpi/parse_font_size). Out-of-range raises
 * ValueError rather than being silently remapped. */
static bool resvg_option_double_range(HashTable *options, uint32_t arg_index, const char *key,
									  double min, double max, double *value)
{
	if (!resvg_option_double(options, arg_index, key, value)) {
		return false;
	}
	if (*value < min || *value > max) {
		zend_argument_value_error(arg_index, "\"%s\" must be between %g and %g", key, min, max);
		return false;
	}

	return true;
}

static bool resvg_option_bool(HashTable *options, uint32_t arg_index, const char *key,
							  bool *value)
{
	zval *entry = resvg_option_find(options, key);

	if (entry == NULL) {
		return true;
	}
	if (Z_TYPE_P(entry) != IS_TRUE && Z_TYPE_P(entry) != IS_FALSE) {
		zend_argument_value_error(arg_index, "\"%s\" must be of type bool", key);
		return false;
	}
	*value = Z_TYPE_P(entry) == IS_TRUE;

	return true;
}

static bool resvg_option_string(HashTable *options, uint32_t arg_index, const char *key,
								zend_string **value)
{
	zval *entry = resvg_option_find(options, key);

	if (entry == NULL) {
		return true;
	}
	if (Z_TYPE_P(entry) != IS_STRING) {
		zend_argument_value_error(arg_index, "\"%s\" must be of type string", key);
		return false;
	}
	*value = Z_STR_P(entry);

	return true;
}

/* Accepts a single string or a list of strings, joined with `separator`. */
static bool resvg_option_list(HashTable *options, uint32_t arg_index, const char *key,
							  char separator, zend_string **value)
{
	zval *entry = resvg_option_find(options, key);

	if (entry == NULL) {
		return true;
	}
	if (Z_TYPE_P(entry) == IS_STRING) {
		*value = Z_STR_P(entry);
		return true;
	}
	if (Z_TYPE_P(entry) != IS_ARRAY) {
		zend_argument_value_error(arg_index, "\"%s\" must be of type string|array", key);
		return false;
	}

	smart_str joined = {0};
	ZEND_HASH_FOREACH_VAL(Z_ARRVAL_P(entry), zval * item)
	{
		if (Z_TYPE_P(item) != IS_STRING) {
			smart_str_free(&joined);
			zend_argument_value_error(arg_index, "\"%s\" must contain only strings", key);
			return false;
		}
		if (joined.s != NULL) {
			smart_str_appendc(&joined, separator);
		}
		smart_str_append(&joined, Z_STR_P(item));
	}
	ZEND_HASH_FOREACH_END();
	smart_str_0(&joined);
	*value = joined.s != NULL ? joined.s : ZSTR_EMPTY_ALLOC();

	return true;
}

/* Maps a rendering-hint name onto its shim discriminant. */
static bool resvg_option_hint(HashTable *options, uint32_t arg_index, const char *key,
							  const struct resvg_hint *table, size_t table_len, int32_t *value)
{
	zend_string *name = NULL;

	if (!resvg_option_string(options, arg_index, key, &name)) {
		return false;
	}
	if (name == NULL) {
		return true;
	}
	for (size_t i = 0; i < table_len; i++) {
		if (zend_string_equals_cstr(name, table[i].name, strlen(table[i].name))) {
			*value = table[i].value;
			return true;
		}
	}

	smart_str allowed = {0};
	for (size_t i = 0; i < table_len; i++) {
		if (i > 0) {
			smart_str_appends(&allowed, ", ");
		}
		smart_str_appends(&allowed, table[i].name);
	}
	smart_str_0(&allowed);
	zend_argument_value_error(arg_index, "\"%s\" must be one of %s", key,
							  allowed.s != NULL ? ZSTR_VAL(allowed.s) : "");
	smart_str_free(&allowed);

	return false;
}

/* Indent accepts `none`, `tabs`, or a space count in 0..4. */
static bool resvg_option_indent(HashTable *options, uint32_t arg_index, const char *key,
								int32_t *value)
{
	zval *entry = resvg_option_find(options, key);

	if (entry == NULL) {
		return true;
	}
	if (Z_TYPE_P(entry) == IS_LONG && Z_LVAL_P(entry) >= 0 && Z_LVAL_P(entry) <= 4) {
		*value = (int32_t)Z_LVAL_P(entry);
		return true;
	}
	if (Z_TYPE_P(entry) == IS_STRING) {
		if (zend_string_equals_literal(Z_STR_P(entry), "none")) {
			*value = RSP_INDENT_NONE;
			return true;
		}
		if (zend_string_equals_literal(Z_STR_P(entry), "tabs")) {
			*value = RSP_INDENT_TABS;
			return true;
		}
	}
	zend_argument_value_error(arg_index,
							  "\"%s\" must be \"none\", \"tabs\", or an int in 0..4", key);

	return false;
}

/* Precision accepts only the 2..8 range the writer supports. */
static bool resvg_option_precision(HashTable *options, uint32_t arg_index, const char *key,
								   uint8_t *value)
{
	zval *entry = resvg_option_find(options, key);

	if (entry == NULL) {
		return true;
	}
	if (Z_TYPE_P(entry) != IS_LONG || Z_LVAL_P(entry) < 2 || Z_LVAL_P(entry) > 8) {
		zend_argument_value_error(arg_index, "\"%s\" must be an int in 2..8", key);
		return false;
	}
	*value = (uint8_t)Z_LVAL_P(entry);

	return true;
}

/* Absent `zoom` means unset (the shim's sentinel); present means a positive
 * factor. The CLI rejects non-positive zoom outright, so a value the oracle
 * refuses must be refused here too rather than silently meaning "unset". */
static bool resvg_option_zoom(HashTable *options, uint32_t arg_index, double *zoom)
{
	if (resvg_option_find(options, "zoom") == NULL) {
		return true;
	}
	if (!resvg_option_double(options, arg_index, "zoom", zoom)) {
		return false;
	}
	if (*zoom <= 0.0) {
		zend_argument_value_error(arg_index, "\"zoom\" must be positive");
		return false;
	}

	return true;
}

bool resvg_options_load_ctor(HashTable *options, uint32_t arg_index,
							 resvg_ctor_options *parsed, const struct resvg_hint *shape_hints, size_t shape_len,
							 const struct resvg_hint *text_hints, size_t text_len, const struct resvg_hint *image_hints,
							 size_t image_len)
{
	memset(parsed, 0, sizeof(*parsed));
	parsed->dpi = RESVG_DEFAULT_DPI;
	parsed->font_size = RESVG_DEFAULT_FONT_SIZE;
	parsed->load_system_fonts = true;
	parsed->shape_rendering = RSP_SHAPE_GEOMETRIC_PRECISION;
	parsed->text_rendering = RSP_TEXT_OPTIMIZE_LEGIBILITY;
	parsed->image_rendering = RSP_IMAGE_OPTIMIZE_QUALITY;

	if (options == NULL) {
		return true;
	}

	static const char *const allowed[] = {
		"dpi",
		"fontSize",
		"width",
		"height",
		"fontFamily",
		"serifFamily",
		"sansSerifFamily",
		"cursiveFamily",
		"fantasyFamily",
		"monospaceFamily",
		"resourcesDir",
		"stylesheet",
		"loadSystemFonts",
		"confineResources",
		"languages",
		"fontFiles",
		"fontDirs",
		"shapeRendering",
		"textRendering",
		"imageRendering",
	};
	if (!resvg_options_reject_unknown(options, arg_index, allowed,
									  sizeof(allowed) / sizeof(allowed[0]))) {
		return false;
	}

	return resvg_option_double_range(options, arg_index, "dpi", 10.0, 4000.0, &parsed->dpi) &&
		   resvg_option_double_range(options, arg_index, "fontSize", 1.0, 192.0,
									 &parsed->font_size) &&
		   resvg_option_uint32(options, arg_index, "width", &parsed->width) &&
		   resvg_option_uint32(options, arg_index, "height", &parsed->height) &&
		   resvg_option_string(options, arg_index, "fontFamily", &parsed->font_family) &&
		   resvg_option_string(options, arg_index, "serifFamily", &parsed->serif_family) &&
		   resvg_option_string(options, arg_index, "sansSerifFamily",
							   &parsed->sans_serif_family) &&
		   resvg_option_string(options, arg_index, "cursiveFamily", &parsed->cursive_family) &&
		   resvg_option_string(options, arg_index, "fantasyFamily", &parsed->fantasy_family) &&
		   resvg_option_string(options, arg_index, "monospaceFamily",
							   &parsed->monospace_family) &&
		   resvg_option_string(options, arg_index, "resourcesDir", &parsed->resources_dir) &&
		   resvg_option_string(options, arg_index, "stylesheet", &parsed->stylesheet) &&
		   resvg_option_bool(options, arg_index, "loadSystemFonts",
							 &parsed->load_system_fonts) &&
		   resvg_option_bool(options, arg_index, "confineResources",
							 &parsed->confine_resources) &&
		   resvg_option_list(options, arg_index, "languages", ',', &parsed->languages) &&
		   resvg_option_list(options, arg_index, "fontFiles", '\n', &parsed->font_files) &&
		   resvg_option_list(options, arg_index, "fontDirs", '\n', &parsed->font_dirs) &&
		   resvg_option_hint(options, arg_index, "shapeRendering", shape_hints, shape_len,
							 &parsed->shape_rendering) &&
		   resvg_option_hint(options, arg_index, "textRendering", text_hints, text_len,
							 &parsed->text_rendering) &&
		   resvg_option_hint(options, arg_index, "imageRendering", image_hints, image_len,
							 &parsed->image_rendering);
}

/* Confinement needs a root. Defaulting it to the process CWD would make the
 * boundary depend on where the server happens to run, so it is required. */
bool resvg_options_check_confine(const resvg_ctor_options *parsed, uint32_t arg_index)
{
	if (parsed->confine_resources && parsed->resources_dir == NULL) {
		zend_argument_value_error(arg_index,
								  "\"confineResources\" requires \"resourcesDir\"");
		return false;
	}

	return true;
}

void resvg_options_load_render(HashTable *options, uint32_t arg_index,
							   uint32_t *width, uint32_t *height, double *zoom, zend_string **background,
							   zend_string **output, int32_t *export_area)
{
	static const struct resvg_hint areas[] = {
		{"drawing", RSP_EXPORT_AREA_DRAWING},
		{"page", RSP_EXPORT_AREA_PAGE},
	};

	*width = 0;
	*height = 0;
	*zoom = 0.0;
	*background = NULL;
	*output = NULL;
	*export_area = RSP_EXPORT_AREA_DRAWING;

	if (options == NULL) {
		return;
	}

	static const char *const allowed[] = {
		"width",
		"height",
		"zoom",
		"background",
		"output",
		"exportArea",
	};
	if (!resvg_options_reject_unknown(options, arg_index, allowed,
									  sizeof(allowed) / sizeof(allowed[0]))) {
		return;
	}

	/* Each loader stops at the first failure: continuing after a throw leaves
	 * partially-written out-params behind an exception the caller may catch. */
	if (!resvg_option_uint32(options, arg_index, "width", width) ||
		!resvg_option_uint32(options, arg_index, "height", height) ||
		!resvg_option_zoom(options, arg_index, zoom) ||
		!resvg_option_string(options, arg_index, "background", background)) {
		return;
	}
	{
		/* The output sink is a stream resource or a writable path; either is
		 * accepted, neither, or both would be a silent behaviour change. */
		zval *entry = resvg_option_find(options, "output");
		if (entry != NULL) {
			if (Z_TYPE_P(entry) == IS_STRING) {
				*output = Z_STR_P(entry);
			} else if (Z_TYPE_P(entry) != IS_RESOURCE) {
				zend_argument_value_error(arg_index,
										  "\"output\" must be of type string|resource");
				return;
			}
		}
	}
	resvg_option_hint(options, arg_index, "exportArea", areas,
					  sizeof(areas) / sizeof(areas[0]), export_area);
}

void resvg_options_load_measure(HashTable *options, uint32_t arg_index, uint32_t *width,
								uint32_t *height, double *zoom)
{
	*width = 0;
	*height = 0;
	*zoom = 0.0;

	if (options == NULL) {
		return;
	}

	static const char *const allowed[] = {"width", "height", "zoom"};
	if (!resvg_options_reject_unknown(options, arg_index, allowed,
									  sizeof(allowed) / sizeof(allowed[0]))) {
		return;
	}

	resvg_option_uint32(options, arg_index, "width", width);
	resvg_option_uint32(options, arg_index, "height", height);
	resvg_option_zoom(options, arg_index, zoom);
}

void resvg_options_load_writer(HashTable *options, uint32_t arg_index,
							   int32_t *preserve_text, zend_string **id_prefix, int32_t *indent, int32_t *attrs_indent,
							   uint8_t *coordinates_precision, uint8_t *transforms_precision, int32_t *use_single_quote)
{
	/* Writer defaults mirror usvg::WriteOptions::default() and the usvg CLI:
	 * indent 4 spaces, attributes indent none, both precisions 8. */
	*preserve_text = 0;
	*id_prefix = NULL;
	*indent = 4;
	*attrs_indent = RSP_INDENT_NONE;
	*coordinates_precision = 8;
	*transforms_precision = 8;
	*use_single_quote = 0;

	if (options == NULL) {
		return;
	}

	static const char *const allowed[] = {
		"preserveText",
		"idPrefix",
		"indent",
		"attrsIndent",
		"coordinatesPrecision",
		"transformsPrecision",
		"useSingleQuote",
	};
	if (!resvg_options_reject_unknown(options, arg_index, allowed,
									  sizeof(allowed) / sizeof(allowed[0]))) {
		return;
	}

	{
		/* Separate variables: a shared `flag` would let the first key's value
		 * leak into the second when the second is absent, since an absent key
		 * leaves its out-param untouched. */
		bool preserve_text_flag = false;
		if (!resvg_option_bool(options, arg_index, "preserveText", &preserve_text_flag)) {
			return;
		}
		*preserve_text = preserve_text_flag ? 1 : 0;

		bool single_quote_flag = false;
		if (!resvg_option_bool(options, arg_index, "useSingleQuote", &single_quote_flag)) {
			return;
		}
		*use_single_quote = single_quote_flag ? 1 : 0;
	}
	if (!resvg_option_string(options, arg_index, "idPrefix", id_prefix) ||
		!resvg_option_indent(options, arg_index, "indent", indent) ||
		!resvg_option_indent(options, arg_index, "attrsIndent", attrs_indent) ||
		!resvg_option_precision(options, arg_index, "coordinatesPrecision",
								coordinates_precision) ||
		!resvg_option_precision(options, arg_index, "transformsPrecision",
								transforms_precision)) {
		return;
	}
}

/* ------------------------------------------------------------------------- */
/* Output delivery and input reading                                         */
/* ------------------------------------------------------------------------- */

void resvg_deliver_output(uint8_t *buffer, uintptr_t length, zend_string *output,
						  zval *return_value)
{
	if (output == NULL) {
		ZVAL_STRINGL(return_value, (const char *)buffer, (size_t)length);
		resvg_php_free(buffer, length);
		return;
	}

	php_stream *stream = php_stream_open_wrapper(ZSTR_VAL(output), "wb", REPORT_ERRORS, NULL);
	if (stream == NULL) {
		resvg_php_free(buffer, length);
		zend_throw_exception(resvg_exception_ce, "Cannot open the output sink for writing", 0);
		RETURN_THROWS();
	}

	size_t written = php_stream_write(stream, (const char *)buffer, (size_t)length);
	php_stream_close(stream);
	resvg_php_free(buffer, length);

	if (written != (size_t)length) {
		zend_throw_exception(resvg_exception_ce,
							 "Failed to write the full PNG to the output sink", 0);
		RETURN_THROWS();
	}

	ZVAL_TRUE(return_value);
}

zend_string *resvg_read_file(zend_string *path, bool *over_ceiling)
{
	*over_ceiling = false;

	php_stream *stream = php_stream_open_wrapper(ZSTR_VAL(path), "rb", REPORT_ERRORS, NULL);

	if (stream == NULL) {
		return NULL;
	}

	/* The ceiling is applied before the copy, not after: copying the whole
	 * stream first would buffer a multi-gigabyte file only to reject it. The
	 * stat short-circuits the common case, and the copy is additionally bounded
	 * at ceiling+1 so a stream that reports no size (or lies) cannot slip past. */
	zend_long ceiling = resvg_max_input_size();
	size_t max_len = PHP_STREAM_COPY_ALL;
	if (ceiling > 0) {
		php_stream_statbuf statbuf;
		if (php_stream_stat(stream, &statbuf) == 0 && statbuf.sb.st_size > 0 &&
			(size_t)statbuf.sb.st_size > (size_t)ceiling) {
			php_stream_close(stream);
			*over_ceiling = true;
			return NULL;
		}
		max_len = (size_t)ceiling + 1;
	}

	zend_string *contents = php_stream_copy_to_mem(stream, max_len, 0);
	php_stream_close(stream);

	/* A stream that lied about its size lands exactly at the bound. */
	if (contents != NULL && ceiling > 0 && ZSTR_LEN(contents) > (size_t)ceiling) {
		zend_string_release(contents);
		*over_ceiling = true;
		return NULL;
	}

	return contents;
}

zend_string *resvg_file_resources_dir(zend_string *path)
{
	char resolved[MAXPATHLEN];

	/* The CLI uses std::fs::canonicalize, which resolves symlinks; expand_filepath
	 * only makes the path absolute. For a file reached through a symlinked
	 * directory the two disagree, and a `..`-bearing href would then resolve
	 * differently from the oracle. tsrm_realpath is PHP's symlink-resolving
	 * equivalent, with expand_filepath as the fallback for a path that does not
	 * exist on disk yet. */
	if (tsrm_realpath(ZSTR_VAL(path), resolved) == NULL &&
		expand_filepath(ZSTR_VAL(path), resolved) == NULL) {
		return NULL;
	}

	char *slash = strrchr(resolved, DEFAULT_SLASH);
	if (slash == NULL) {
		return NULL;
	}
	*slash = '\0';

	return zend_string_init(resolved, strlen(resolved), 0);
}
