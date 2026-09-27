<?php

/** @generate-class-entries */

namespace Resvg
{
    class Exception extends \RuntimeException
    {
    }

    final class Renderer
    {
        public function __construct(array $options = [])
        {
        }

        public function render(string $svg, array $options = []): string
        {
        }

        /** @return array{width: int, height: int} */
        public function measure(string $svg, array $options = []): array
        {
        }

        public static function version(): string
        {
        }
    }
}
