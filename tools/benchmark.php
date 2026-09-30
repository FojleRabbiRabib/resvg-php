#!/usr/bin/env php
<?php

/**
 * Benchmark runner and regression ratchet for resvg-php.
 *
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 *
 * Reports throughput (renders/second) and real OS memory (VmRSS / VmHWM) per
 * workload. Never relies solely on PHP's memory_get_usage(), which cannot see
 * the Rust allocator, tiny-skia pixmap surfaces, or native fontdb tables.
 *
 * Usage:
 *   php tools/benchmark.php [--record=baseline.json]
 *       [--compare=baseline.json] [--iterations=N] [--threshold=0.15]
 */

declare(strict_types=1);

if (!extension_loaded('resvg')) {
    fwrite(STDERR, "benchmark: the resvg extension is not loaded\n");
    exit(2);
}

$options = getopt('', ['record:', 'compare:', 'iterations:', 'threshold:']);
$recordFile = isset($options['record']) && is_string($options['record']) ? $options['record'] : null;
$compareFile = isset($options['compare']) && is_string($options['compare']) ? $options['compare'] : null;
$iterations = 200;
if (isset($options['iterations']) && is_string($options['iterations'])) {
    $iterations = max(10, (int) $options['iterations']);
}
$threshold = isset($options['threshold']) && is_string($options['threshold']) ? (float) $options['threshold'] : 0.15;

/**
 * @return array{rss_kb: int, hwm_kb: int}
 */
function get_real_memory_kb(): array
{
    $statusFile = '/proc/self/status';
    if (is_readable($statusFile)) {
        $content = (string) file_get_contents($statusFile);
        $vmRss = preg_match('/^VmRSS:\s+(\d+)\s+kB/m', $content, $m) ? (int) $m[1] : 0;
        $vmHwm = preg_match('/^VmHWM:\s+(\d+)\s+kB/m', $content, $m) ? (int) $m[1] : 0;
        return ['rss_kb' => $vmRss, 'hwm_kb' => $vmHwm];
    }
    $usage = getrusage();
    $maxRss = $usage['ru_maxrss'] ?? 0;
    // macOS and BSD report ru_maxrss in bytes, Linux in kilobytes; normalize
    // so recorded baselines compare like-for-like.
    if (PHP_OS_FAMILY === 'Darwin' || PHP_OS_FAMILY === 'BSD') {
        $maxRss = (int) ($maxRss / 1024);
    }
    return ['rss_kb' => (int) $maxRss, 'hwm_kb' => (int) $maxRss];
}

$fixtureDir = __DIR__ . '/../tests/fixtures';
$font = dirname($fixtureDir) . '/vendor/DejaVuSans.ttf';

$workloads = [
    'shapes' => [
        'description' => 'Basic geometric paths (shapes.svg)',
        'file' => $fixtureDir . '/shapes.svg',
        'ctor' => ['loadSystemFonts' => false],
        'render' => ['width' => 128],
    ],
    'gradient' => [
        'description' => 'Gradients and blending (gradient.svg)',
        'file' => $fixtureDir . '/gradient.svg',
        'ctor' => ['loadSystemFonts' => false],
        'render' => ['width' => 256],
    ],
    'text' => [
        'description' => 'Text rendering with pinned font (text.svg)',
        'file' => $fixtureDir . '/text.svg',
        'ctor' => ['fontFiles' => [$font], 'loadSystemFonts' => false],
        'render' => [],
    ],
];

echo "========================================================================\n";
printf("resvg-php benchmark ratchet (resvg %s, PHP %s)\n", Resvg\Renderer::version(), PHP_VERSION);
printf("Iterations per workload: %d\n", $iterations);
echo "========================================================================\n";

$results = [
    'version' => Resvg\Renderer::version(),
    'php_version' => PHP_VERSION,
    'timestamp' => date('c'),
    'iterations' => $iterations,
    'cases' => [],
];

foreach ($workloads as $id => $spec) {
    $svg = (string) file_get_contents($spec['file']);
    $renderer = new Resvg\Renderer($spec['ctor']);

    // Warm-up
    for ($i = 0; $i < 5; $i++) {
        $renderer->render($svg, $spec['render']);
    }

    $memBefore = get_real_memory_kb();
    $start = microtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $renderer->render($svg, $spec['render']);
    }
    $elapsed = microtime(true) - $start;
    $memAfter = get_real_memory_kb();

    $rps = $iterations / $elapsed;
    $msPerOp = ($elapsed / $iterations) * 1000.0;

    $results['cases'][$id] = [
        'description' => $spec['description'],
        'rps' => round($rps, 2),
        'ms_per_op' => round($msPerOp, 3),
        'rss_kb' => $memAfter['rss_kb'],
        'hwm_kb' => $memAfter['hwm_kb'],
    ];

    printf(
        "%-20s %8.1f ops/sec  %6.3f ms/op  VmRSS: %6d kB  VmHWM: %6d kB\n",
        $id,
        $rps,
        $msPerOp,
        $memAfter['rss_kb'],
        $memAfter['hwm_kb'],
    );
}

// Tree reuse benchmark: parse once, render many vs render()
$svg = (string) file_get_contents($workloads['shapes']['file']);
$renderer = new Resvg\Renderer(['loadSystemFonts' => false]);
$tree = $renderer->parse($svg);

$start = microtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $tree->render();
}
$elapsedTree = microtime(true) - $start;
$treeRps = $iterations / $elapsedTree;

$results['cases']['tree-reuse'] = [
    'description' => 'Parse once, render many (Tree::render())',
    'rps' => round($treeRps, 2),
    'ms_per_op' => round(($elapsedTree / $iterations) * 1000.0, 3),
    'rss_kb' => get_real_memory_kb()['rss_kb'],
    'hwm_kb' => get_real_memory_kb()['hwm_kb'],
];

printf(
    "%-20s %8.1f ops/sec  %6.3f ms/op  (tree parse once vs re-parse)\n",
    'tree-reuse',
    $treeRps,
    ($elapsedTree / $iterations) * 1000.0,
);

echo "------------------------------------------------------------------------\n";

if ($recordFile !== null) {
    $json = json_encode($results, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    if ($json === false || file_put_contents($recordFile, $json . "\n") === false) {
        fwrite(STDERR, "benchmark: failed to write baseline to $recordFile\n");
        exit(1);
    }
    echo "Recorded baseline to $recordFile\n";
}

if ($compareFile !== null) {
    if (!is_file($compareFile)) {
        fwrite(STDERR, "benchmark: baseline file not found: $compareFile\n");
        exit(1);
    }
    $raw = (string) file_get_contents($compareFile);
    $baseline = json_decode($raw, true);
    if (!is_array($baseline) || !isset($baseline['cases']) || !is_array($baseline['cases'])) {
        fwrite(STDERR, "benchmark: invalid baseline format in $compareFile\n");
        exit(1);
    }

    echo "Regression comparison vs baseline:\n";
    $regressions = 0;
    foreach ($results['cases'] as $id => $case) {
        if (!isset($baseline['cases'][$id])) {
            continue;
        }
        $baseRps = (float) $baseline['cases'][$id]['rps'];
        if ($baseRps <= 0.0) {
            fwrite(STDERR, "benchmark: invalid baseline rps for case $id in $compareFile\n");
            exit(1);
        }
        $currRps = (float) $case['rps'];
        $delta = ($currRps - $baseRps) / $baseRps;
        $deltaPct = $delta * 100.0;

        $status = 'OK';
        if ($delta < -$threshold) {
            $status = 'REGRESSION';
            $regressions++;
        }
        printf(
            "  %-15s baseline: %8.1f  current: %8.1f  delta: %+6.1f%% [%s]\n",
            $id,
            $baseRps,
            $currRps,
            $deltaPct,
            $status,
        );
    }

    if ($regressions > 0) {
        $pct = sprintf('%.0f', $threshold * 100);
        fwrite(STDERR, "benchmark: $regressions case(s) regressed past $pct% threshold\n");
        exit(1);
    }
    echo "Benchmark ratchet OK: zero throughput regressions past threshold\n";
}

exit(0);
