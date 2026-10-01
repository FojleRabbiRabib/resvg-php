<?php

/**
 * The public API of the resvg extension. Mirrors resvg_arginfo.h and the design
 * record's locked surface; the CI arginfo-drift gate regenerates the arginfo
 * bodies from this file and fails on any diff. Class entries and the
 * `Resvg\Exception` constants are registered in C on purpose: the constant
 * values come from the same RESVG_STATUS_* macros as the throw sites, so the
 * declared codes can never drift from the raised ones. gen_stub therefore runs
 * without @generate-class-entries and emits arginfo declarations only; the
 * signatures below are the single source for those declarations.
 *
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

namespace Resvg
{
    /**
     * A renderer failure. The code is one of the class constants, which are the
     * ABI status codes; the message carries the parser's own detail when the
     * renderer produced one.
     */
    class Exception extends \RuntimeException
    {
        public const int PARSE_FAILED = 4;
        public const int NOT_UTF8 = 2;
        public const int INVALID_SIZE = 3;
        public const int ELEMENTS_LIMIT = 11;
        public const int MALFORMED_GZIP = 12;
        public const int SVGZ_DISABLED = 13;
        public const int NO_SUCH_NODE = 9;
        public const int ZERO_SIZE_NODE = 10;
        public const int ENCODE_FAILED = 6;
        public const int ALLOCATION_FAILED = 5;
        public const int INVALID_ARGUMENT = 8;
        public const int INTERNAL = 7;
        public const int TOO_LARGE = 14;
    }

    final class Renderer
    {
        /**
         * The option keys mirror the design record's locked surface; unknown
         * keys and wrongly typed values raise ValueError.
         */
        public function __construct(array $options = [])
        {
        }

        /**
         * Parses an SVG or SVGZ document, reusing the renderer's font database.
         * Returns a self-contained Tree.
         */
        public function parse(string $svg): Tree
        {
        }

        /** Parses the file at the given path. Returns a self-contained Tree. */
        public function parseFile(string $path): Tree
        {
        }

        /**
         * Returns the encoded PNG, or true when `output` sends it to a sink.
         */
        public function render(string $svg, array $options = []): string|bool
        {
        }

        /**
         * Returns the encoded PNG, or true when `output` sends it to a sink.
         */
        public function renderFile(string $path, array $options = []): string|bool
        {
        }

        /**
         * Returns the pixel dimensions a render with the same options would
         * produce, without rasterizing: a width/height map.
         */
        public function measure(string $svg, array $options = []): array
        {
        }

        /**
         * Returns the pixel dimensions for the file at the given path: a
         * width/height map.
         */
        public function measureFile(string $path, array $options = []): array
        {
        }

        /**
         * The loaded font faces as a family => path map.
         */
        public function fonts(): array
        {
        }

        /** The extension version plus the vendored resvg pin, e.g. "0.2.0+resvg.0.48.1". */
        public static function version(): string
        {
        }
    }

    /**
     * A parsed document: parse once, render many. Self-contained — it carries its
     * own font database, so it may outlive the renderer that produced it.
     *
     * Constructed only by the renderer; `new Tree()` is not valid usage, and the
     * private constructor keeps a handle-less instance out of userland.
     */
    final class Tree
    {
        private function __construct()
        {
        }

        /** The document's intrinsic size in user units, as a width/height map. */
        public function size(): array
        {
        }

        /**
         * The drawing's bounding box as an x/y/width/height map, or null when
         * the document draws nothing.
         */
        public function boundingBox(): ?array
        {
        }

        /** Whether an element with this id exists. */
        public function hasNode(string $id): bool
        {
        }

        /**
         * Every id in the document, in document order.
         */
        public function nodeIds(): array
        {
        }

        /**
         * Returns the encoded PNG, or true when `output` sends it to a sink.
         */
        public function render(array $options = []): string|bool
        {
        }

        /**
         * Renders one node by id, `--export-id` semantics. Returns the encoded
         * PNG, or true when `output` sends it to a sink.
         */
        public function renderNode(string $id, array $options = []): string|bool
        {
        }

        /**
         * Serializes the document back to SVG through upstream's writer.
         */
        public function toSvg(array $options = []): string
        {
        }
    }
}
