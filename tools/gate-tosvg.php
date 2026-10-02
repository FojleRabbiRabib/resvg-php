#!/usr/bin/env php
<?php

/**
 * toSvg fidelity gate: `Tree::toSvg()` output must be byte-identical to the
 * upstream `usvg` CLI built from the same vendored source — the writer-path
 * analogue of `gate-render.php`'s PNG oracle.
 *
 * Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0
 *
 * A fixture is a *row* of (svg, toSvg option set), not a bare SVG, so a writer
 * default or range that drifts is caught here. Rows live in
 * fixtures/tosvg-rows.php; every `*.svg` is additionally written once with the
 * default options.
 *
 * A row marked `self` has no CLI equivalent (the `usvg` CLI hardcodes the value)
 * and is checked by the property that defines it instead — see the rows file.
 *
 * Env: USVG_ORACLE — path to the usvg binary
 *      (default: vendor-src/resvg-<version>/target/release/usvg).
 */

declare(strict_types=1);

$oracleEnv = getenv('USVG_ORACLE');
$oracle = $oracleEnv !== false && $oracleEnv !== ''
    ? $oracleEnv
    : __DIR__ . '/../vendor-src/resvg-0.48.1/target/release/usvg';
if (!is_file($oracle) || !is_executable($oracle)) {
    fwrite(STDERR, "gate-tosvg: usvg oracle not found at {$oracle}; build it with tools/build-oracle.sh\n");
    exit(2);
}

$fixtureDir = __DIR__ . '/../tests/fixtures';
$config = require $fixtureDir . '/tosvg-rows.php';
$rows = $config['rows'];
$fileDefaults = $config['fileDefaults'] ?? [];

foreach (glob($fixtureDir . '/*.svg') ?: [] as $svgPath) {
    $defaults = $fileDefaults[basename($svgPath)] ?? [];
    $rows[] = [
        'name' => basename($svgPath),
        'file' => $svgPath,
        'ctor' => $defaults['ctor'] ?? [],
        'toSvg' => [],
        'cli' => $defaults['cli'] ?? [],
    ];
}

$failures = 0;

foreach ($rows as $row) {
    $name = $row['name'] ?? basename($row['file']);

    try {
        $renderer = new Resvg\Renderer($row['ctor'] ?? []);
        $tree = $renderer->parseFile($row['file']);
        $actual = $tree->toSvg($row['toSvg'] ?? []);
    } catch (Throwable $e) {
        printf("ERROR %-22s %s\n", $name, $e->getMessage());
        $failures++;
        continue;
    }

    if ($row['self'] ?? false) {
        // Self-consistency: the flag must flip every attribute delimiter and
        // nothing else. Compare against the same options with it off.
        $off = $tree->toSvg(array_merge($row['toSvg'] ?? [], ['useSingleQuote' => false]));
        $expected = str_replace('"', "'", $off);
        if ($expected === $actual) {
            printf("PASS  %-22s %s (self)\n", $name, hash('sha256', $actual));
            continue;
        }
        printf("DRIFT %-22s self-consistency (bytes %d vs %d)\n", $name, strlen($expected), strlen($actual));
        $failures++;
        continue;
    }

    $oracleSvg = tempnam(sys_get_temp_dir(), 'rsp-usvg-');
    if ($oracleSvg === false) {
        fwrite(STDERR, "gate-tosvg: cannot allocate temp file\n");
        exit(2);
    }

    $cmd = sprintf(
        '%s %s %s %s ' . (PHP_OS_FAMILY === 'Windows' ? '2>NUL' : '2>/dev/null'),
        escapeshellarg($oracle),
        implode(' ', array_map('escapeshellarg', $row['cli'] ?? [])),
        escapeshellarg($row['file']),
        escapeshellarg($oracleSvg),
    );
    exec($cmd, output: $ignored, result_code: $code);
    if ($code !== 0) {
        fwrite(STDERR, sprintf("gate-tosvg: oracle failed on %s (exit %d)\n", $name, $code));
        unlink($oracleSvg);
        $failures++;
        continue;
    }
    $expected = (string) file_get_contents($oracleSvg);
    unlink($oracleSvg);

    if ($expected === $actual) {
        printf("PASS  %-22s %s\n", $name, hash('sha256', $actual));
        continue;
    }

    printf(
        "DRIFT %-22s oracle=%s ext=%s (bytes %d vs %d)\n",
        $name,
        substr(hash('sha256', $expected), 0, 16),
        substr(hash('sha256', $actual), 0, 16),
        strlen($expected),
        strlen($actual),
    );
    $failures++;
}

if ($failures > 0) {
    fwrite(STDERR, sprintf("gate-tosvg: %d drift failure(s)\n", $failures));
    exit(1);
}

printf("gate-tosvg: %d row(s), byte-identical to the usvg oracle\n", count($rows));
