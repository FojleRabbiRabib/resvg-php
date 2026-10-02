#!/usr/bin/env php
<?php

/**
 * Fidelity gate: the extension's PNG output must be byte-identical to the
 * upstream resvg CLI built from the same vendored source.
 *
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 *
 * A fixture is a *row* of (svg, option set), not a bare SVG, so option drift is
 * caught as well as renderer drift. Rows live in fixtures/rows.php; every
 * `*.svg` file is additionally rendered once with the default options, so a new
 * document is covered the moment it is dropped in.
 *
 * Env: RESVG_ORACLE — path to the oracle binary
 *      (default: vendor-src/resvg-<version>/target/release/resvg).
 */

declare(strict_types=1);

$oracleEnv = getenv('RESVG_ORACLE');
$oracle = $oracleEnv !== false && $oracleEnv !== ''
    ? $oracleEnv
    : __DIR__ . '/../vendor-src/resvg-0.48.1/target/release/resvg';
if (!is_file($oracle) || !is_executable($oracle)) {
    fwrite(STDERR, "gate: oracle binary not found at {$oracle}; build it with tools/build-oracle.sh\n");
    exit(2);
}

$fixtureDir = __DIR__ . '/../tests/fixtures';

/**
 * A row is: file, ctor options, render options, and the CLI flags the oracle
 * needs to reproduce the same call. The extension side is (ctor, render);
 * `cli` is the oracle equivalent, and keeping both in one row is what makes a
 * drift between them visible.
 *
 * `fileDefaults` supplies ctor/cli defaults for the auto-generated row of a
 * given basename, for a document whose default rendering already needs to pin
 * something (a text fixture must pin its font or the row is host-dependent).
 */
$config = require $fixtureDir . '/rows.php';
$rows = $config['rows'];
$fileDefaults = $config['fileDefaults'] ?? [];

foreach (glob($fixtureDir . '/*.svg') ?: [] as $svgPath) {
    // The oracle always renders a file, so the extension side must too — a
    // string-parse row could not resolve a relative href and would drift for a
    // reason that is not a defect.
    $defaults = $fileDefaults[basename($svgPath)] ?? [];
    $rows[] = [
        'name' => basename($svgPath),
        'file' => $svgPath,
        'ctor' => $defaults['ctor'] ?? [],
        'render' => [],
        'cli' => $defaults['cli'] ?? [],
        'viaFile' => true,
    ];
}

$failures = 0;

foreach ($rows as $row) {
    $name = $row['name'] ?? basename($row['file']);
    $svg = (string) file_get_contents($row['file']);

    $oraclePng = tempnam(sys_get_temp_dir(), 'rsp-oracle-');
    if ($oraclePng === false) {
        fwrite(STDERR, "gate: cannot allocate temp file\n");
        exit(2);
    }

    // Silence the oracle's stderr: cmd.exe (Windows) and /bin/sh disagree on
    // the null-device spelling, and exec() routes through the platform shell.
    $cmd = sprintf(
        '%s %s %s %s ' . (PHP_OS_FAMILY === 'Windows' ? '2>NUL' : '2>/dev/null'),
        escapeshellarg($oracle),
        implode(' ', array_map('escapeshellarg', $row['cli'] ?? [])),
        escapeshellarg($row['file']),
        escapeshellarg($oraclePng),
    );
    exec($cmd, output: $ignored, result_code: $code);
    if ($code !== 0) {
        fwrite(STDERR, sprintf("gate: oracle failed on %s (exit %d)\n", $name, $code));
        unlink($oraclePng);
        $failures++;
        continue;
    }

    $expected = (string) file_get_contents($oraclePng);
    unlink($oraclePng);

    try {
        $renderer = new Resvg\Renderer($row['ctor'] ?? []);
        $tree = ($row['viaFile'] ?? false)
            ? $renderer->parseFile($row['file'])
            : $renderer->parse($svg);
        $actual = isset($row['renderNode'])
            ? $tree->renderNode($row['renderNode'], $row['render'] ?? [])
            : $tree->render($row['render'] ?? []);
    } catch (Throwable $e) {
        printf("ERROR %-24s %s\n", $name, $e->getMessage());
        $failures++;
        continue;
    }

    if (!is_string($actual)) {
        printf("ERROR %-24s render returned bool; the gate rows never use a sink\n", $name);
        $failures++;
        continue;
    }

    if ($expected === $actual) {
        printf("PASS  %-24s %s\n", $name, hash('sha256', $actual));
        continue;
    }

    printf(
        "DRIFT %-24s oracle=%s ext=%s (bytes %d vs %d)\n",
        $name,
        substr(hash('sha256', $expected), 0, 16),
        substr(hash('sha256', $actual), 0, 16),
        strlen($expected),
        strlen($actual),
    );
    $failures++;
}

if ($failures > 0) {
    fwrite(STDERR, sprintf("gate: %d drift failure(s)\n", $failures));
    exit(1);
}

printf("gate: %d row(s), byte-identical to the oracle\n", count($rows));
