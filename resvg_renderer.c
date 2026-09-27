/*
 * resvg-php — Renderer class: option marshalling and the render/measure entry points.
 *
 * The PHP object owns one long-lived shim handle because building the font database
 * scans system font directories and must never repeat per render.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "php.h"
#include "ext/spl/spl_exceptions.h"
#include "Zend/zend_exceptions.h"
#include "Zend/zend_smart_str.h"
#include "resvg_arginfo.h"
#include "resvg_internal.h"

zend_class_entry *resvg_renderer_ce = NULL;
static zend_class_entry *resvg_exception_ce = NULL;
static zend_object_handlers resvg_renderer_handlers;

/* Options accepted by the constructor, resolved from the PHP array. */
typedef struct {
	zend_string *font_family;
	zend_string *languages;
	zend_string *resources_dir;
	zend_string *stylesheet;
	zend_string *font_files;
	double dpi;
	double font_size;
	uint32_t width;
	uint32_t height;
} resvg_ctor_options;

/* Per-call render overrides. Zeros mean "use the configured default". */
typedef struct {
	uint32_t width;
	uint32_t height;
	double zoom;
	zend_string *background;
} resvg_render_options;

static void resvg_throw_status(int32_t status)
{
	const char *message;

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
	case RESVG_STATUS_NULL_POINTER:
	case RESVG_STATUS_INTERNAL:
	default:
		message = "Internal renderer failure was contained";
		break;
	}

	zend_throw_exception(resvg_exception_ce, message, 0);
}

static bool resvg_option_get(HashTable *options, const char *key, zval **entry)
{
	*entry = options != NULL
				 ? zend_hash_str_find(options, key, strlen(key))
				 : NULL;

	return *entry != NULL;
}

static bool resvg_option_double(HashTable *options, uint32_t arg_index, const char *key,
								double *value)
{
	zval *entry;

	if (!resvg_option_get(options, key, &entry)) {
		return true;
	}
	if (Z_TYPE_P(entry) != IS_LONG && Z_TYPE_P(entry) != IS_DOUBLE) {
		zend_argument_value_error(arg_index, "\"%s\" must be of type float", key);
		return false;
	}
	*value = zval_get_double(entry);

	return true;
}

static bool resvg_option_uint32(HashTable *options, uint32_t arg_index, const char *key,
								uint32_t *value)
{
	zval *entry;

	if (!resvg_option_get(options, key, &entry)) {
		return true;
	}
	if (Z_TYPE_P(entry) != IS_LONG || Z_LVAL_P(entry) < 0 || Z_LVAL_P(entry) > UINT32_MAX) {
		zend_argument_value_error(arg_index, "\"%s\" must be a non-negative int", key);
		return false;
	}
	*value = (uint32_t)Z_LVAL_P(entry);

	return true;
}

static bool resvg_option_string(HashTable *options, uint32_t arg_index, const char *key,
								zend_string **value)
{
	zval *entry;

	if (!resvg_option_get(options, key, &entry)) {
		return true;
	}
	if (Z_TYPE_P(entry) != IS_STRING) {
		zend_argument_value_error(arg_index, "\"%s\" must be of type string", key);
		return false;
	}
	*value = Z_STR_P(entry);

	return true;
}

/* Accepts a single string or a list of strings; either shape becomes one joined string. */
static bool resvg_option_list(HashTable *options, uint32_t arg_index, const char *key,
							  char separator, zend_string **value)
{
	zval *entry;

	if (!resvg_option_get(options, key, &entry)) {
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

static bool resvg_ctor_options_load(HashTable *options, uint32_t arg_index,
									resvg_ctor_options *parsed)
{
	memset(parsed, 0, sizeof(*parsed));
	parsed->dpi = RESVG_DEFAULT_DPI;
	parsed->font_size = RESVG_DEFAULT_FONT_SIZE;

	return resvg_option_double(options, arg_index, "dpi", &parsed->dpi) &&
		   resvg_option_double(options, arg_index, "fontSize", &parsed->font_size) &&
		   resvg_option_uint32(options, arg_index, "width", &parsed->width) &&
		   resvg_option_uint32(options, arg_index, "height", &parsed->height) &&
		   resvg_option_string(options, arg_index, "fontFamily", &parsed->font_family) &&
		   resvg_option_string(options, arg_index, "resourcesDir", &parsed->resources_dir) &&
		   resvg_option_string(options, arg_index, "stylesheet", &parsed->stylesheet) &&
		   resvg_option_list(options, arg_index, "languages", ',', &parsed->languages) &&
		   resvg_option_list(options, arg_index, "fontFiles", '\n', &parsed->font_files);
}

static bool resvg_render_options_load(HashTable *options, uint32_t arg_index,
									  resvg_render_options *parsed)
{
	memset(parsed, 0, sizeof(*parsed));

	return resvg_option_uint32(options, arg_index, "width", &parsed->width) &&
		   resvg_option_uint32(options, arg_index, "height", &parsed->height) &&
		   resvg_option_double(options, arg_index, "zoom", &parsed->zoom) &&
		   resvg_option_string(options, arg_index, "background", &parsed->background);
}

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
	resvg_renderer_object *renderer =
		ecalloc(1, sizeof(resvg_renderer_object) + zend_object_properties_size(ce));

	zend_object_std_init(&renderer->std, ce);
	object_properties_init(&renderer->std, ce);
	renderer->std.handlers = &resvg_renderer_handlers;

	return &renderer->std;
}

static bool resvg_renderer_require_handle(resvg_renderer_object *renderer)
{
	if (renderer->handle != NULL) {
		return true;
	}

	zend_throw_exception(resvg_exception_ce, "Renderer is not initialized", 0);

	return false;
}

void resvg_render_or_throw(resvg_renderer_object *renderer, zend_string *svg,
						   HashTable *options, zval *return_value)
{
	resvg_render_options parsed;

	if (!resvg_render_options_load(options, 2, &parsed)) {
		RETURN_THROWS();
	}

	uint8_t *png = NULL;
	uintptr_t png_len = 0;
	int32_t status = resvg_php_render(renderer->handle, (const uint8_t *)ZSTR_VAL(svg),
									  ZSTR_LEN(svg), parsed.width, parsed.height, (float)parsed.zoom,
									  parsed.background != NULL ? ZSTR_VAL(parsed.background) : NULL, &png, &png_len);

	if (status != RESVG_STATUS_OK) {
		if (parsed.background != NULL) {
			zend_argument_value_error(2, "\"background\" is not a valid color");
		}
		resvg_throw_status(status);
		RETURN_THROWS();
	}

	RETVAL_STRINGL((const char *)png, (size_t)png_len);
	resvg_php_free(png, png_len);
}

void resvg_measure_or_throw(resvg_renderer_object *renderer, zend_string *svg,
							HashTable *options, zval *return_value)
{
	resvg_render_options parsed;

	if (!resvg_render_options_load(options, 2, &parsed)) {
		RETURN_THROWS();
	}

	uint32_t width = 0;
	uint32_t height = 0;
	int32_t status = resvg_php_measure(renderer->handle, (const uint8_t *)ZSTR_VAL(svg),
									   ZSTR_LEN(svg), parsed.width, parsed.height, (float)parsed.zoom, &width, &height);

	if (status != RESVG_STATUS_OK) {
		resvg_throw_status(status);
		RETURN_THROWS();
	}

	array_init(return_value);
	add_assoc_long(return_value, "width", (zend_long)width);
	add_assoc_long(return_value, "height", (zend_long)height);
}

PHP_METHOD(Resvg_Renderer, __construct)
{
	HashTable *options = NULL;

	ZEND_PARSE_PARAMETERS_START(0, 1)
	Z_PARAM_OPTIONAL
	Z_PARAM_ARRAY_HT(options)
	ZEND_PARSE_PARAMETERS_END();

	resvg_renderer_object *renderer = Z_RESVG_RENDERER_P(ZEND_THIS);
	resvg_ctor_options parsed;

	if (options == NULL || zend_hash_num_elements(options) == 0) {
		memset(&parsed, 0, sizeof(parsed));
		parsed.dpi = RESVG_DEFAULT_DPI;
		parsed.font_size = RESVG_DEFAULT_FONT_SIZE;
	} else if (!resvg_ctor_options_load(options, 1, &parsed)) {
		RETURN_THROWS();
	}

	renderer->handle = resvg_php_options_create(
		parsed.resources_dir != NULL ? ZSTR_VAL(parsed.resources_dir) : NULL,
		(float)parsed.dpi,
		parsed.font_family != NULL ? ZSTR_VAL(parsed.font_family) : NULL,
		(float)parsed.font_size,
		parsed.languages != NULL ? ZSTR_VAL(parsed.languages) : NULL,
		parsed.font_files != NULL ? ZSTR_VAL(parsed.font_files) : NULL,
		parsed.stylesheet != NULL ? ZSTR_VAL(parsed.stylesheet) : NULL, parsed.width,
		parsed.height);

	if (renderer->handle == NULL) {
		zend_throw_exception(resvg_exception_ce,
							 "Failed to initialize the render configuration", 0);
		RETURN_THROWS();
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

	if (!resvg_renderer_require_handle(Z_RESVG_RENDERER_P(ZEND_THIS))) {
		RETURN_THROWS();
	}

	resvg_render_or_throw(Z_RESVG_RENDERER_P(ZEND_THIS), svg, options, return_value);
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

	if (!resvg_renderer_require_handle(Z_RESVG_RENDERER_P(ZEND_THIS))) {
		RETURN_THROWS();
	}

	resvg_measure_or_throw(Z_RESVG_RENDERER_P(ZEND_THIS), svg, options, return_value);
}

PHP_METHOD(Resvg_Renderer, version)
{
	ZEND_PARSE_PARAMETERS_NONE();

	RETURN_STRING(resvg_php_version());
}

static const zend_function_entry resvg_renderer_methods[] = {
	PHP_ME(Resvg_Renderer, __construct, arginfo_class_Resvg_Renderer___construct,
		   ZEND_ACC_PUBLIC)
		PHP_ME(Resvg_Renderer, render, arginfo_class_Resvg_Renderer_render, ZEND_ACC_PUBLIC)
			PHP_ME(Resvg_Renderer, measure, arginfo_class_Resvg_Renderer_measure, ZEND_ACC_PUBLIC)
				PHP_ME(Resvg_Renderer, version, arginfo_class_Resvg_Renderer_version,
					   ZEND_ACC_PUBLIC | ZEND_ACC_STATIC)
					PHP_FE_END};

zend_result resvg_register_renderer_class(void)
{
	zend_class_entry ce;

	INIT_NS_CLASS_ENTRY(ce, "Resvg", "Exception", NULL);
	resvg_exception_ce = zend_register_internal_class_ex(&ce, spl_ce_RuntimeException);

	INIT_NS_CLASS_ENTRY(ce, "Resvg", "Renderer", resvg_renderer_methods);
	resvg_renderer_ce = zend_register_internal_class(&ce);
	resvg_renderer_ce->ce_flags |= ZEND_ACC_FINAL;
	resvg_renderer_ce->create_object = resvg_renderer_create_object;

	memcpy(&resvg_renderer_handlers, &std_object_handlers, sizeof(zend_object_handlers));
	resvg_renderer_handlers.free_obj = resvg_renderer_free_storage;
	resvg_renderer_handlers.clone_obj = NULL;

	return SUCCESS;
}
