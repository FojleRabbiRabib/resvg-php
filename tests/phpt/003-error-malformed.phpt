--TEST--
Resvg\Renderer rejects malformed SVG with Resvg\Exception
--EXTENSIONS--
resvg
--FILE--
<?php
/* Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0 */
$renderer = new Resvg\Renderer();

try {
    $renderer->render('not an svg document');
} catch (Resvg\Exception $e) {
    var_dump($e instanceof RuntimeException);
    var_dump($e->getCode());
    // The message carries the parser's own detail when upstream produced one.
    echo strstr($e->getMessage(), ':', true), "\n";
}
?>
--EXPECT--
bool(true)
int(4)
Failed to parse the SVG document
