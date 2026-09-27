// resvg-php shim ABI — hand-written mirror of native/src/lib.rs.
// Keep both sides in lockstep; the link step catches drift, the fidelity gate
// catches semantic drift.

#ifndef RESVG_PHP_SHIM_H
#define RESVG_PHP_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct resvg_php_options resvg_php_options;

/* Status codes (native/src/lib.rs) */
#define RSP_OK 0
#define RSP_ERROR_NULL_POINTER 1
#define RSP_ERROR_UTF8 2
#define RSP_ERROR_INVALID_SIZE 3
#define RSP_ERROR_PARSING 4
#define RSP_ERROR_ALLOCATION 5
#define RSP_ERROR_ENCODE 6
#define RSP_ERROR_INTERNAL 7
#define RSP_ERROR_INVALID_ARGUMENT 8

resvg_php_options *resvg_php_options_create(
	const char *resources_dir,
	float dpi,
	const char *font_family,
	float font_size,
	const char *languages,
	const char *font_files, /* newline-separated paths */
	const char *stylesheet,
	uint32_t width, uint32_t height);

int32_t resvg_php_render(
	const resvg_php_options *options,
	const uint8_t *data, uintptr_t len,
	uint32_t width, uint32_t height, float zoom,
	const char *background,
	uint8_t **out, uintptr_t *out_len);

int32_t resvg_php_measure(
	const resvg_php_options *options,
	const uint8_t *data, uintptr_t len,
	uint32_t width, uint32_t height, float zoom,
	uint32_t *out_width, uint32_t *out_height);

void resvg_php_options_free(resvg_php_options *options);

void resvg_php_free(uint8_t *ptr, uintptr_t len);

const char *resvg_php_version(void);

#ifdef __cplusplus
}
#endif

#endif /* RESVG_PHP_SHIM_H */
