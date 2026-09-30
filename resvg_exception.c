/*
 * resvg-php — Resvg\Exception class registration.
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "php.h"
#include "ext/spl/spl_exceptions.h"
#include "php_resvg.h"
#include "resvg_arginfo.h"
#include "resvg_internal.h"

zend_class_entry *resvg_exception_ce = NULL;

/* The class constants are the ABI status codes; the same set appears in
 * resvg_internal.h, resvg_php_shim.h, and resvg.stub.php. `getCode()` is
 * inherited from RuntimeException and returns the code passed at throw time. */
zend_result resvg_register_exception_class(void)
{
	zend_class_entry ce;

	INIT_NS_CLASS_ENTRY(ce, "Resvg", "Exception", NULL);
	resvg_exception_ce = zend_register_internal_class_ex(&ce, spl_ce_RuntimeException);
	if (resvg_exception_ce == NULL) {
		return FAILURE;
	}

#define RESVG_DECLARE_STATUS(name, value) \
	zend_declare_class_constant_long(resvg_exception_ce, name, sizeof(name) - 1, value)
	RESVG_DECLARE_STATUS("PARSE_FAILED", RESVG_STATUS_PARSING);
	RESVG_DECLARE_STATUS("NOT_UTF8", RESVG_STATUS_UTF8);
	RESVG_DECLARE_STATUS("INVALID_SIZE", RESVG_STATUS_INVALID_SIZE);
	RESVG_DECLARE_STATUS("ELEMENTS_LIMIT", RESVG_STATUS_ELEMENTS_LIMIT);
	RESVG_DECLARE_STATUS("MALFORMED_GZIP", RESVG_STATUS_MALFORMED_GZIP);
	RESVG_DECLARE_STATUS("SVGZ_DISABLED", RESVG_STATUS_SVGZ_DISABLED);
	RESVG_DECLARE_STATUS("NO_SUCH_NODE", RESVG_STATUS_NO_SUCH_NODE);
	RESVG_DECLARE_STATUS("ZERO_SIZE_NODE", RESVG_STATUS_ZERO_SIZE_NODE);
	RESVG_DECLARE_STATUS("ENCODE_FAILED", RESVG_STATUS_ENCODE);
	RESVG_DECLARE_STATUS("ALLOCATION_FAILED", RESVG_STATUS_ALLOCATION);
	RESVG_DECLARE_STATUS("INVALID_ARGUMENT", RESVG_STATUS_INVALID_ARGUMENT);
	RESVG_DECLARE_STATUS("INTERNAL", RESVG_STATUS_INTERNAL);
	RESVG_DECLARE_STATUS("TOO_LARGE", RESVG_STATUS_TOO_LARGE);
#undef RESVG_DECLARE_STATUS

	return SUCCESS;
}
