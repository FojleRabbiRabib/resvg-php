<?php

/**
 * Render an SVG document to a PNG file, with sizing, background, and measurement.
 *
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 *
 * Usage: php -n -d extension=build/resvg-php8.3.so examples/basic-render.php [output.png]
 */

declare(strict_types=1);

$output = $argv[1] ?? 'build/example-basic.png';

if (!extension_loaded('resvg')) {
    fwrite(STDERR, "The resvg extension is not loaded.\n");
    exit(1);
}

$svg = <<<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#7dd3fc"/>
      <stop offset="1" stop-color="#1e3a8a"/>
    </linearGradient>
  </defs>
  <rect width="120" height="120" rx="16" fill="url(#sky)"/>
  <circle cx="60" cy="52" r="22" fill="#fde047"/>
  <rect x="0" y="88" width="120" height="32" fill="#065f46"/>
</svg>
SVG;

$renderer = new Resvg\Renderer();

$measured = $renderer->measure($svg);
if ($measured !== ['width' => 120, 'height' => 120]) {
    throw new RuntimeException('Unexpected intrinsic size: ' . var_export($measured, true));
}

$png = $renderer->render($svg, ['width' => 240, 'background' => '#ffffff']);
if (!is_string($png)) {
    throw new RuntimeException('Render returned bool, but no "output" sink was given.');
}
if (strncmp($png, "\x89PNG\r\n\x1a\n", 8) !== 0) {
    throw new RuntimeException('Output is not a PNG.');
}

$scaled = $renderer->measure($svg, ['width' => 240]);
if ($scaled['width'] !== 240 || $scaled['height'] !== 240) {
    throw new RuntimeException('Unexpected scaled size: ' . var_export($scaled, true));
}

if (file_put_contents($output, $png) === false) {
    throw new RuntimeException("Cannot write {$output}.");
}

printf(
    "Wrote %s (%d bytes, %dx%d), resvg %s\n",
    $output,
    strlen($png),
    $measured['width'],
    $measured['height'],
    Resvg\Renderer::version(),
);
