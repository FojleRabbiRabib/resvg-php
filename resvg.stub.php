<?php

/**
 * The public API of the resvg extension. Mirrors resvg_arginfo.h and the design
 * record's locked surface; the CI arginfo-drift gate regenerates resvg_arginfo.h
 * from this file and fails on any diff.
 *
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

/** @generate-class-entries */

namespace Resvg
{
    /**
     * A renderer failure. The code is one of the class constants, which are the
     * ABI status codes; the message carries the parser's own detail when the
     * renderer produced one.
     */
    class Exception extends \RuntimeException
    {
        public const PARSE_FAILED = 4;
        public const NOT_UTF8 = 2;
        public const INVALID_SIZE = 3;
        public const ELEMENTS_LIMIT = 11;
        public const MALFORMED_GZIP = 12;
        public const SVGZ_DISABLED = 13;
        public const NO_SUCH_NODE = 9;
        public const ZERO_SIZE_NODE = 10;
        public const ENCODE_FAILED = 6;
        public const ALLOCATION_FAILED = 5;
        public const INVALID_ARGUMENT = 8;
        public const INTERNAL = 7;
        public const TOO_LARGE = 14;
    }

    final class Renderer
    {
        /**
         * @param array<string, mixed> $options
         */
        public function __construct(array $options = [])
        {
        }

        /**
         * Parses an SVG or SVGZ document, reusing the renderer's font database.
         *
         * @return Tree
         */
        public function parse(string $svg): Tree
        {
        }

        /** @return Tree */
        public function parseFile(string $path): Tree
        {
        }

        /**
         * Returns the encoded PNG, or true when `output` sends it to a sink.
         *
         * @param array<string, mixed> $options
         */
        public function render(string $svg, array $options = []): string|bool
        {
        }

        /**
         * Returns the encoded PNG, or true when `output` sends it to a sink.
         *
         * @param array<string, mixed> $options
         */
        public function renderFile(string $path, array $options = []): string|bool
        {
        }

        /**
         * @param array<string, mixed> $options
         * @return array{width: int, height: int}
         */
        public function measure(string $svg, array $options = []): array
        {
        }

        /**
         * @param array<string, mixed> $options
         * @return array{width: int, height: int}
         */
        public function measureFile(string $path, array $options = []): array
        {
        }

        /**
         * The loaded font faces as a family => path map.
         *
         * @return array<string, string>
         */
        public function fonts(): array
        {
        }

        /** The extension version plus the vendored resvg pin, e.g. "0.1.0+resvg.0.48.1". */
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

        /** @return array{width: float, height: float} */
        public function size(): array
        {
        }

        /** @return array{x: float, y: float, width: float, height: float}|null */
        public function boundingBox(): ?array
        {
        }

        public function hasNode(string $id): bool
        {
        }

        /**
         * Every id in the document, in document order.
         *
         * @return list<string>
         */
        public function nodeIds(): array
        {
        }

        /**
         * Returns the encoded PNG, or true when `output` sends it to a sink.
         *
         * @param array<string, mixed> $options
         */
        public function render(array $options = []): string|bool
        {
        }

        /**
         * Renders one node by id, `--export-id` semantics. Returns the encoded
         * PNG, or true when `output` sends it to a sink.
         *
         * @param array<string, mixed> $options
         */
        public function renderNode(string $id, array $options = []): string|bool
        {
        }

        /**
         * Serializes the document back to SVG through upstream's writer.
         *
         * @param array<string, mixed> $options
         */
        public function toSvg(array $options = []): string
        {
        }
    }
}
