<?php

/**
 * Lifecycle churn: exercises allocator hygiene, object destruction, error paths,
 * and Tree-outliving-Renderer semantics under Valgrind.
 *
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

declare(strict_types=1);

$svg = '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">'
    . '<rect width="64" height="64" fill="#369"/><circle cx="32" cy="32" r="20" fill="#fc3"/></svg>';

$malformed = '<svg xmlns="http://www.w3.org/2000/svg"><path d="M 0 0 ZZZ"/></svg>';

// 1. Renderer construction and teardown loops
for ($i = 0; $i < 20; $i++) {
    $r = new Resvg\Renderer(['loadSystemFonts' => false, 'dpi' => 120]);
    $png = $r->render($svg);
    if (!is_string($png) || !str_starts_with($png, "\x89PNG")) {
        throw new RuntimeException("lifecycle-churn: render failed at iteration $i");
    }
    unset($r);
}

// 2. Tree outliving its Renderer
$trees = [];
for ($i = 0; $i < 10; $i++) {
    $r = new Resvg\Renderer(['loadSystemFonts' => false]);
    $trees[] = $r->parse($svg);
    unset($r);
}
foreach ($trees as $i => $tree) {
    $png = $tree->render(['width' => 32, 'height' => 32]);
    $svgOut = $tree->toSvg();
    if (!is_string($png) || $svgOut === '') {
        throw new RuntimeException("lifecycle-churn: tree outliving renderer failed at $i");
    }
}
unset($trees);

// 3. Error path churn: failures must release all native allocations
$r = new Resvg\Renderer(['loadSystemFonts' => false]);
for ($i = 0; $i < 20; $i++) {
    try {
        $r->render($malformed);
    } catch (Resvg\Exception) {
        // expected
    }

    try {
        $tree = $r->parse($svg);
        $tree->renderNode('nonexistent-id');
    } catch (Resvg\Exception) {
        // expected
    }

    try {
        ini_set('resvg.max_render_pixels', '100');
        $r->render($svg);
    } catch (Resvg\Exception) {
        // expected
    } finally {
        ini_restore('resvg.max_render_pixels');
    }
}

// 4. Constructor re-entry
for ($i = 0; $i < 10; $i++) {
    $r = new Resvg\Renderer(['loadSystemFonts' => false]);
    $r->__construct(['loadSystemFonts' => false, 'dpi' => 72]);
    $png = $r->render($svg);
    if (!is_string($png)) {
        throw new RuntimeException("lifecycle-churn: constructor re-entry failed at $i");
    }
}

echo "lifecycle churn done\n";
