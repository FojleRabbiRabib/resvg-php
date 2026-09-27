--TEST--
Resvg\Renderer::measure reports the render size without encoding a PNG
--EXTENSIONS--
resvg
--FILE--
<?php
$renderer = new Resvg\Renderer();
$svg = '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60">'
    . '<rect width="120" height="60"/></svg>';

var_dump($renderer->measure($svg));
var_dump($renderer->measure($svg, ['width' => 240]));
var_dump($renderer->measure($svg, ['zoom' => 0.5]));
?>
--EXPECT--
array(2) {
  ["width"]=>
  int(120)
  ["height"]=>
  int(60)
}
array(2) {
  ["width"]=>
  int(240)
  ["height"]=>
  int(120)
}
array(2) {
  ["width"]=>
  int(60)
  ["height"]=>
  int(30)
}
