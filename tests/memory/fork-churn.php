<?php

/**
 * Fork churn: build the renderer and tree BEFORE forking, then render in children.
 * The fork contract is that the shim holds no locks, threads, or descriptors, so a
 * child inherits a usable handle via copy-on-write and owns its own allocations.
 *
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 */

declare(strict_types=1);

$svg = '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48">'
    . '<rect width="48" height="48" fill="#369"/><circle cx="24" cy="24" r="16" fill="#fc3"/></svg>';

if (!function_exists('pcntl_fork')) {
    echo "pcntl unavailable\n";
    exit(0);
}

$renderer = new Resvg\Renderer(['loadSystemFonts' => false]);
$tree = $renderer->parse($svg);

$pids = [];
for ($i = 0; $i < 4; $i++) {
    $pid = pcntl_fork();
    if ($pid === -1) {
        echo "fork failed\n";
        exit(1);
    }
    if ($pid === 0) {
        $png = $tree->render();
        $svgOut = $tree->toSvg();
        $r2 = new Resvg\Renderer(['loadSystemFonts' => false]);
        $r2->parse($svg)->render();
        try {
            $renderer->render('not svg');
        } catch (Throwable $e) {
            // expected: exercises the error path in a forked child
        }
        $ok = is_string($png) && str_starts_with($png, "\x89PNG") && $svgOut !== '';
        exit($ok ? 0 : 1);
    }
    $pids[] = $pid;
}

$bad = 0;
foreach ($pids as $pid) {
    pcntl_waitpid($pid, $status);
    if (pcntl_wexitstatus($status) !== 0) {
        $bad++;
    }
}
echo $bad === 0 ? "fork churn done\n" : "fork churn FAILED ($bad)\n";
exit($bad === 0 ? 0 : 1);
