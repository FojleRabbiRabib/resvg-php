/*
 * resvg-php — module lifecycle, class registration, and extension info.
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

PHP_MINIT_FUNCTION(resvg)
{
	(void)type;
	(void)module_number;

	if (resvg_register_renderer_class() != SUCCESS) {
		return FAILURE;
	}

	return SUCCESS;
}

PHP_MINFO_FUNCTION(resvg)
{
	(void)zend_module;

	php_info_print_table_start();
	php_info_print_table_header(2, "resvg support", "enabled");
	php_info_print_table_row(2, "Version", PHP_RESVG_VERSION);
	php_info_print_table_row(2, "Upstream resvg", resvg_php_version());
	php_info_print_table_end();
}

zend_module_entry resvg_module_entry = {
	STANDARD_MODULE_HEADER,
	PHP_RESVG_EXTNAME,
	NULL, /* functions — class methods only */
	PHP_MINIT(resvg),
	NULL, /* MSHUTDOWN */
	NULL, /* RINIT */
	NULL, /* RSHUTDOWN */
	PHP_MINFO(resvg),
	PHP_RESVG_VERSION,
	STANDARD_MODULE_PROPERTIES};

ZEND_GET_MODULE(resvg)
