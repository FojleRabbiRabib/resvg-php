#!/usr/bin/env php
<?php

/**
 * Minimal .phpt runner.
 *
 * PHP's own run-tests.php ships with php-src, which is not required to build this
 * extension, so the suite runs through this driver instead. It supports the sections
 * this project uses: TEST, EXTENSIONS, FILE, EXPECT, and EXPECTF.
 *
 * Usage: php tools/test-phpt.php <resvg.so> [tests/]
 */

declare(strict_types=1);

$extension = $argv[1] ?? '';
$testDir = $argv[2] ?? __DIR__ . '/../tests';

if ($extension === '' || !is_file($extension)) {
    fwrite(STDERR, "test-phpt: usage: php tools/test-phpt.php <resvg.so> [tests/]\n");
    exit(2);
}
$extension = realpath($extension);
if ($extension === false) {
    fwrite(STDERR, "test-phpt: cannot resolve extension path\n");
    exit(2);
}

$files = glob(rtrim($testDir, '/') . '/*.phpt');
if ($files === false || $files === []) {
    fwrite(STDERR, "test-phpt: no .phpt files in {$testDir}\n");
    exit(2);
}
sort($files);

$passed = 0;
$failed = 0;

foreach ($files as $file) {
    $sections = [];
    $current = null;
    foreach (file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^--([A-Z]+)--$/', $line, $m)) {
            $current = $m[1];
            $sections[$current] = '';
            continue;
        }
        if ($current !== null) {
            $sections[$current] .= $line . "\n";
        }
    }

    $name = trim($sections['TEST'] ?? basename($file));
    if (!isset($sections['FILE'])) {
        fwrite(STDERR, "test-phpt: {$name} has no --FILE-- section\n");
        $failed++;
        continue;
    }

    $script = tempnam(sys_get_temp_dir(), 'rsp-phpt-');
    if ($script === false) {
        fwrite(STDERR, "test-phpt: cannot allocate a temp script\n");
        exit(2);
    }
    file_put_contents($script, $sections['FILE']);

    $output = [];
    $code = 0;
    exec(
        sprintf(
            '%s -n -d extension=%s %s 2>&1',
            escapeshellarg(PHP_BINARY),
            escapeshellarg($extension),
            escapeshellarg($script),
        ),
        $output,
        $code,
    );
    unlink($script);
    $actual = implode("\n", $output) . "\n";

    if (isset($sections['EXPECT'])) {
        $matches = $actual === $sections['EXPECT'];
    } elseif (isset($sections['EXPECTF'])) {
        $pattern = preg_quote($sections['EXPECTF'], '/');
        $pattern = str_replace(['%d', '%s', '%a', '%w'], ['\d+', '.*?', '.*', '\s*'], $pattern);
        $matches = (bool) preg_match('/^' . $pattern . '$/s', $actual);
    } else {
        fwrite(STDERR, "test-phpt: {$name} has no --EXPECT-- or --EXPECTF-- section\n");
        $failed++;
        continue;
    }

    if ($matches && $code === 0) {
        echo "PASS {$name}\n";
        $passed++;
        continue;
    }

    echo "FAIL {$name}\n";
    if (isset($sections['EXPECT'])) {
        echo "--- expected ---\n{$sections['EXPECT']}--- actual ---\n{$actual}----------------\n";
    }
    $failed++;
}

printf("test-phpt: %d passed, %d failed\n", $passed, $failed);
exit($failed === 0 ? 0 : 1);
