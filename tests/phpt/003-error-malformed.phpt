--TEST--
Resvg\Renderer rejects malformed SVG with Resvg\Exception
--EXTENSIONS--
resvg
--FILE--
<?php
$renderer = new Resvg\Renderer();

try {
    $renderer->render('not an svg document');
} catch (Resvg\Exception $e) {
    var_dump($e instanceof RuntimeException);
    echo $e->getMessage(), "\n";
}
?>
--EXPECT--
bool(true)
Failed to parse the SVG document
