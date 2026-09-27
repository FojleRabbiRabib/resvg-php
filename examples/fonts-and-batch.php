<?php

/**
 * Render text with an explicit font, and show that a reusable renderer is the
 * intended shape: construct once, render many.
 *
 * Usage: php -n -d extension=build/resvg-php8.3.so examples/fonts-and-batch.php
 */

declare(strict_types=1);

if (!extension_loaded('resvg')) {
    fwrite(STDERR, "The resvg extension is not loaded.\n");
    exit(1);
}

$renderer = new Resvg\Renderer([
    'fontFamily' => 'DejaVu Sans',
    'languages' => ['en'],
]);

$labels = ['Alpha', 'Bravo', 'Charlie'];
$hashes = [];

foreach ($labels as $label) {
    $svg = sprintf(
        '<svg xmlns="http://www.w3.org/2000/svg" width="220" height="48">'
        . '<rect width="220" height="48" fill="#111827"/>'
        . '<text x="12" y="32" font-family="DejaVu Sans" font-size="24" fill="#f9fafb">%s</text>'
        . '</svg>',
        htmlspecialchars($label, ENT_XML1),
    );

    $png = $renderer->render($svg);
    if (strncmp($png, "\x89PNG\r\n\x1a\n", 8) !== 0) {
        throw new RuntimeException("Render of '{$label}' is not a PNG.");
    }

    $hashes[$label] = hash('sha256', $png);
}

if (count(array_unique($hashes)) !== count($labels)) {
    throw new RuntimeException('Distinct labels produced identical output.');
}

printf("Rendered %d labels with distinct output; resvg %s\n", count($labels), Resvg\Renderer::version());
