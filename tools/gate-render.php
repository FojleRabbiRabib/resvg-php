#!/usr/bin/env php
<?php

/**
 * Fidelity gate: the extension's PNG output must be byte-identical to the
 * upstream resvg CLI built from the same vendored source.
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
$fixtures = glob($fixtureDir . '/*.svg');
if ($fixtures === false || $fixtures === []) {
    fwrite(STDERR, "gate: no fixtures in {$fixtureDir}\n");
    exit(2);
}

$renderer = new Resvg\Renderer();
$failures = 0;

foreach ($fixtures as $svgPath) {
    $oraclePng = tempnam(sys_get_temp_dir(), 'rsp-oracle-');
    if ($oraclePng === false) {
        fwrite(STDERR, "gate: cannot allocate temp file\n");
        exit(2);
    }

    $cmd = sprintf(
        '%s %s %s 2>/dev/null',
        escapeshellarg($oracle),
        escapeshellarg($svgPath),
        escapeshellarg($oraclePng),
    );
    exec($cmd, output: $ignored, result_code: $code);
    if ($code !== 0) {
        fwrite(STDERR, sprintf("gate: oracle failed on %s (exit %d)\n", basename($svgPath), $code));
        unlink($oraclePng);
        $failures++;
        continue;
    }

    $expected = (string) file_get_contents($oraclePng);
    unlink($oraclePng);

    $actual = $renderer->render((string) file_get_contents($svgPath));

    if ($expected === $actual) {
        printf("PASS  %-16s %s\n", basename($svgPath), hash('sha256', $actual));
        continue;
    }

    printf(
        "DRIFT %-16s oracle=%s ext=%s (bytes %d vs %d)\n",
        basename($svgPath),
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

printf("gate: %d fixture(s), byte-identical to the oracle\n", count($fixtures));
