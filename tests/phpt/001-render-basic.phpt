--TEST--
Resvg\Renderer renders an SVG document to PNG bytes
--EXTENSIONS--
resvg
--FILE--
<?php
/* Copyright 2026 Fojle Rabbi (Rabib)
 * SPDX-License-Identifier: Apache-2.0 */
$renderer = new Resvg\Renderer();
$svg = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">'
    . '<rect width="16" height="16" fill="#123456"/></svg>';
$png = $renderer->render($svg);

var_dump(strncmp($png, "\x89PNG\r\n\x1a\n", 8) === 0);
var_dump(strlen($png) > 0);

/* PNG IHDR width/height live at a fixed offset in every PNG this encoder emits. */
$ihdr = unpack('Nwidth/Nheight', substr($png, 16, 8));
var_dump($ihdr['width'], $ihdr['height']);
?>
--EXPECT--
bool(true)
bool(true)
int(16)
int(16)
