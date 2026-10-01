/*
 * resvg-php — module lifecycle, INI entries, class registration, and phpinfo().
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "php.h"
#include "ext/standard/info.h"
#include "php_resvg.h"
#include "resvg_arginfo.h"
#include "resvg_php_shim.h"
#include "resvg_internal.h"

#if defined(ZTS) && defined(COMPILE_DL_RESVG)
ZEND_TSRMLS_CACHE_DEFINE()
#endif

ZEND_DECLARE_MODULE_GLOBALS(resvg)

static PHP_GINIT_FUNCTION(resvg)
{
#if defined(COMPILE_DL_RESVG) && defined(ZTS)
	ZEND_TSRMLS_CACHE_UPDATE();
#endif
	resvg_globals->max_input_size = RESVG_DEFAULT_MAX_INPUT_SIZE;
	resvg_globals->max_render_pixels = RESVG_DEFAULT_MAX_RENDER_PIXELS;
}

PHP_INI_BEGIN()
STD_PHP_INI_ENTRY(RESVG_INI_MAX_INPUT_SIZE, "16777216", PHP_INI_ALL, OnUpdateLong,
				  max_input_size, zend_resvg_globals, resvg_globals)
STD_PHP_INI_ENTRY(RESVG_INI_MAX_RENDER_PIXELS, "67108864", PHP_INI_ALL, OnUpdateLong,
				  max_render_pixels, zend_resvg_globals, resvg_globals)
PHP_INI_END()

PHP_MINIT_FUNCTION(resvg)
{
	(void)type;
	(void)module_number;

	REGISTER_INI_ENTRIES();

	if (resvg_register_exception_class() != SUCCESS ||
		resvg_register_tree_class() != SUCCESS ||
		resvg_register_renderer_class() != SUCCESS) {
		return FAILURE;
	}

	return SUCCESS;
}

PHP_MSHUTDOWN_FUNCTION(resvg)
{
	(void)type;
	(void)module_number;

	UNREGISTER_INI_ENTRIES();

	return SUCCESS;
}

PHP_MINFO_FUNCTION(resvg)
{
	(void)zend_module;

	char ceiling_input[32];
	char ceiling_pixels[32];
	char default_font[128];
	snprintf(ceiling_input, sizeof(ceiling_input), ZEND_LONG_FMT, RESVG_G(max_input_size));
	snprintf(ceiling_pixels, sizeof(ceiling_pixels), ZEND_LONG_FMT, RESVG_G(max_render_pixels));
	snprintf(default_font, sizeof(default_font), "%s @ %d", RESVG_DEFAULT_FONT_FAMILY,
			 (int)RESVG_DEFAULT_FONT_SIZE);

	/* The shim reports the composite `0.2.0+resvg.0.48.1`; the pin is the part
	 * after the marker, so this row tracks the vendored source with no second
	 * constant to keep in lockstep. */
	const char *composite = resvg_php_version();
	const char *pin = strstr(composite, "resvg.");
	pin = pin != NULL ? pin + sizeof("resvg.") - 1 : composite;

	php_info_print_table_start();
	php_info_print_table_header(2, "resvg support", "enabled");
	php_info_print_table_row(2, "Version", PHP_RESVG_VERSION);
	php_info_print_table_row(2, "Upstream resvg", pin);
#ifdef ZTS
	php_info_print_table_row(2, "Thread safety", "enabled (ZTS)");
#else
	php_info_print_table_row(2, "Thread safety", "disabled (NTS)");
#endif
	php_info_print_table_row(2, "Features",
							 "svgz, text, system-fonts, memmap-fonts, raster-images");
	php_info_print_table_row(2, "Default font", default_font);
	php_info_print_table_row(2, "System fonts", "loaded by default: yes");
	php_info_print_table_row(2, RESVG_INI_MAX_INPUT_SIZE, ceiling_input);
	php_info_print_table_row(2, RESVG_INI_MAX_RENDER_PIXELS, ceiling_pixels);
	php_info_print_table_row(2, "Author", "Fojle Rabbi (Rabib)");
	php_info_print_table_end();

	DISPLAY_INI_ENTRIES();
}

zend_module_entry resvg_module_entry = {
	STANDARD_MODULE_HEADER,
	PHP_RESVG_EXTNAME,
	NULL, /* functions — class methods only */
	PHP_MINIT(resvg),
	PHP_MSHUTDOWN(resvg),
	NULL, /* RINIT */
	NULL, /* RSHUTDOWN */
	PHP_MINFO(resvg),
	PHP_RESVG_VERSION,
	PHP_MODULE_GLOBALS(resvg),
	PHP_GINIT(resvg),
	NULL, /* GSHUTDOWN */
	NULL, /* post deactivate */
	STANDARD_MODULE_PROPERTIES_EX};

ZEND_GET_MODULE(resvg)
