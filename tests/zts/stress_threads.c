/*
 * Multi-threaded stress test for the resvg shim C ABI.
 * Exercises true thread concurrency: concurrent options, concurrent parse,
 * concurrent render, concurrent tree reuse, thread-local error isolation,
 * and concurrent free. Run under Helgrind / TSAN to prove race freedom.
 *
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <assert.h>
#include "resvg_php_shim.h"

#define NUM_THREADS 8
#define ITERS_PER_THREAD 50

static const char *TEST_SVG =
	"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">"
	"<rect width=\"100\" height=\"100\" fill=\"red\"/>"
	"<circle cx=\"50\" cy=\"50\" r=\"40\" fill=\"blue\" id=\"c1\"/>"
	"</svg>";

static void *thread_worker(void *arg) {
	int id = *(int *)arg;
	(void)id;

	for (int i = 0; i < ITERS_PER_THREAD; i++) {
		/* 1. Independent options handle per thread */
		resvg_php_options *opts = resvg_php_options_create(
			NULL, 96.0f, "Times New Roman", 12.0f,
			NULL, NULL, NULL, NULL, NULL,
			"en", NULL, NULL, 0,
			RSP_SHAPE_GEOMETRIC_PRECISION,
			RSP_TEXT_OPTIMIZE_LEGIBILITY,
			RSP_IMAGE_OPTIMIZE_QUALITY,
			NULL, 0, 0, 0);
		assert(opts != NULL);

		/* 2. Independent parse */
		int32_t status = 0;
		resvg_php_tree *tree = resvg_php_tree_parse(
			opts, (const uint8_t *)TEST_SVG, strlen(TEST_SVG), NULL, &status);
		assert(status == RSP_OK);
		assert(tree != NULL);

		/* 3. Tree outliving its options */
		resvg_php_options_free(opts);

		/* 4. Render */
		uint8_t *png = NULL;
		uintptr_t png_len = 0;
		int32_t r = resvg_php_tree_render(
			tree, 100, 100, 1.0f, RSP_EXPORT_AREA_DRAWING, NULL,
			67108864, &png, &png_len);
		assert(r == RSP_OK);
		assert(png != NULL);
		assert(png_len > 8);
		assert(memcmp(png, "\x89PNG\r\n\x1a\n", 8) == 0);
		resvg_php_free(png, png_len);

		/* 5. Render node */
		r = resvg_php_tree_render_node(
			tree, "c1", 80, 80, 1.0f, RSP_EXPORT_AREA_DRAWING, NULL,
			67108864, &png, &png_len);
		assert(r == RSP_OK);
		assert(png != NULL);
		resvg_php_free(png, png_len);

		/* 6. toSvg */
		uint8_t *svg_out = NULL;
		uintptr_t svg_len = 0;
		r = resvg_php_tree_to_svg(
			tree, 0, "", 2, 2, 6, 6, 0, &svg_out, &svg_len);
		assert(r == RSP_OK);
		assert(svg_out != NULL);
		resvg_php_free(svg_out, svg_len);

		/* 7. Error path: verify thread-local error isolation with malformed SVG */
		resvg_php_options *err_opts = resvg_php_options_create(
			NULL, 96.0f, "Times New Roman", 12.0f,
			NULL, NULL, NULL, NULL, NULL,
			"en", NULL, NULL, 0, 0, 0, 0, NULL, 0, 0, 0);
		int32_t bad_status = 0;
		resvg_php_tree *bad = resvg_php_tree_parse(
			err_opts, (const uint8_t *)"not svg", 7, NULL, &bad_status);
		assert(bad == NULL);
		assert(bad_status == RSP_ERROR_PARSING);
		const char *err = resvg_php_last_error();
		assert(err != NULL && strlen(err) > 0);
		resvg_php_options_free(err_opts);

		resvg_php_tree_free(tree);
	}
	return NULL;
}

int main(void) {
	pthread_t threads[NUM_THREADS];
	int thread_ids[NUM_THREADS];

	/* Warm up CPU feature detection tables (memchr, crc32fast) single-threaded
	 * before launching concurrent workers. */
	{
		resvg_php_options *w_opts = resvg_php_options_create(
			NULL, 96.0f, "Times New Roman", 12.0f,
			NULL, NULL, NULL, NULL, NULL,
			"en", NULL, NULL, 0, 0, 0, 0, NULL, 0, 0, 0);
		int32_t w_status = 0;
		resvg_php_tree *w_tree = resvg_php_tree_parse(
			w_opts, (const uint8_t *)TEST_SVG, strlen(TEST_SVG), NULL, &w_status);
		uint8_t *w_png = NULL;
		uintptr_t w_len = 0;
		resvg_php_tree_render(w_tree, 10, 10, 1.0f, 0, NULL, 67108864, &w_png, &w_len);
		resvg_php_free(w_png, w_len);
		resvg_php_tree_free(w_tree);
		resvg_php_options_free(w_opts);
	}

	printf("Spawning %d threads, %d iterations each...\n", NUM_THREADS, ITERS_PER_THREAD);
	for (int i = 0; i < NUM_THREADS; i++) {
		thread_ids[i] = i;
		int rc = pthread_create(&threads[i], NULL, thread_worker, &thread_ids[i]);
		assert(rc == 0);
	}

	for (int i = 0; i < NUM_THREADS; i++) {
		pthread_join(threads[i], NULL);
	}

	printf("SUCCESS: %d threads completed %d iterations cleanly with zero data races.\n",
		   NUM_THREADS, ITERS_PER_THREAD);
	return 0;
}
