/*
 * Generated arginfo for the resvg extension (mirrors resvg.stub.php).
 * Revisit with php-src's build/gen_stub.php once a php-src checkout is available.
 */

#ifndef RESVG_ARGINFO_H
#define RESVG_ARGINFO_H

ZEND_BEGIN_ARG_INFO_EX(arginfo_class_Resvg_Renderer___construct, 0, 0, 0)
ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, options, IS_ARRAY, 0, "[]")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Resvg_Renderer_render, 0, 1, IS_STRING, 0)
ZEND_ARG_TYPE_INFO(0, svg, IS_STRING, 0)
ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, options, IS_ARRAY, 0, "[]")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Resvg_Renderer_measure, 0, 1, IS_ARRAY, 0)
ZEND_ARG_TYPE_INFO(0, svg, IS_STRING, 0)
ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, options, IS_ARRAY, 0, "[]")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Resvg_Renderer_version, 0, 0, IS_STRING, 0)
ZEND_END_ARG_INFO()

#endif /* RESVG_ARGINFO_H */
