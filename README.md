# resvg-php

Render SVG to PNG from PHP — in-process, dependency-free, with the full SVG feature
set of [resvg](https://github.com/linebender/resvg).

```php
$renderer = new Resvg\Renderer();
$png = $renderer->render(file_get_contents('chart.svg'));
file_put_contents('chart.png', $png);
```

## Why

PHP has no real SVG renderer. The usual options are all painful:

- `shell_exec('inkscape ...')` or `rsvg-convert` — spawns a process, needs a binary
  installed, and pipes data through the filesystem.
- ImageMagick's SVG delegate — notorious for CVE history, broken CSS support, and
  silent rendering differences across builds.
- GD — has no SVG support at all.

`resvg-php` loads the renderer into the PHP process itself. No external binary, no
subprocess, no temp files. The vendored renderer is the reference SVG implementation:
it supports the full SVG 1.1/2 static feature set, CSS selectors, filters, masks,
clipping, text with web fonts, and gradient/mesh painting, and it renders
deterministically — the same input produces the same bytes on every machine.

## Requirements

- PHP 8.3, 8.4, or 8.5, non-thread-safe (NTS) builds
- x86-64 Linux with glibc
- For building from source: Rust 1.85 or newer, and a PHP development toolchain

ZTS (thread-safe) builds are not yet validated; the extension is tested on NTS only.

## Installation

### Prebuilt

Download the `.so` matching your PHP ABI from the releases page and add it to your
`php.ini`:

```ini
extension=/path/to/resvg-php8.3.so
```

### From source

```sh
tools/build.sh 8.3
```

The artifact lands in `build/resvg-php8.3.so`. The build fetches the pinned resvg
source, verifies its SHA-256, compiles the Rust bridge to a static archive, and links
it into a self-contained extension.

## Usage

### Rendering

`Resvg\Renderer::render()` takes an SVG document as a string and returns PNG bytes.

```php
$renderer = new Resvg\Renderer();

$png = $renderer->render('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">
    <circle cx="8" cy="8" r="7" fill="#2b6cb0"/>
</svg>');

file_put_contents('icon.png', $png);
```

A renderer holds a font database, so build one and reuse it. Constructing a renderer
per call re-scans the system fonts and is dramatically slower.

```php
$renderer = new Resvg\Renderer();          // once, e.g. in a service container

foreach ($icons as $icon) {
    $png = $renderer->render($icon);       // many
}
```

### Sizing

By default the output matches the SVG's own size. Pass `width`, `height`, or `zoom`
per render to change it.

```php
$renderer->render($svg, ['width' => 512]);          // scale to width
$renderer->render($svg, ['height' => 512]);         // scale to height
$renderer->render($svg, ['width' => 512, 'height' => 512]); // exact pixel size
$renderer->render($svg, ['zoom' => 2.0]);           // scale by factor
```

### Background

SVG output normally keeps transparency. Set a background color when you need an opaque
image.

```php
$renderer->render($svg, ['background' => '#ffffff']);
```

### Text and fonts

The renderer loads the system font database automatically. Set defaults for documents
that rely on the user agent's font settings, or load your own font files.

```php
$renderer = new Resvg\Renderer([
    'fontFamily' => 'Inter',
    'fontSize' => 16,
    'languages' => ['en', 'bn'],
    'fontFiles' => ['/var/www/fonts/Inter-Regular.ttf'],
]);
```

`fontFiles` accepts a single path or an array; `languages` accepts a comma-separated
string or an array.

### Measuring without rendering

`measure()` reports the pixel size a render would produce, without rasterizing.

```php
['width' => $w, 'height' => $h] = $renderer->measure($svg, ['width' => 512]);
```

### Version

```php
Resvg\Renderer::version();   // "0.1.0+resvg.0.48.1"
```

## Options reference

Constructor options:

| Option | Type | Default | Description |
|---|---|---|---|
| `fontFamily` | string | `"Times New Roman"` | Family used when the SVG sets no `font-family`. |
| `fontSize` | float | `12.0` | Size used when the SVG sets no `font-size`. |
| `languages` | string\|string[] | `"en"` | Resolves the `systemLanguage` attribute. |
| `fontFiles` | string\|string[] | — | Extra font files to load. |
| `resourcesDir` | string | — | Base directory for relative paths in the SVG. |
| `stylesheet` | string | — | CSS injected into every document, overriding its own rules. |
| `dpi` | float | `96.0` | Affects unit conversion. |
| `width` | int | — | Default width for documents without absolute dimensions. |
| `height` | int | — | Default height for documents without absolute dimensions. |

Per-render options:

| Option | Type | Description |
|---|---|---|
| `width` | int | Target width in pixels. |
| `height` | int | Target height in pixels. |
| `zoom` | float | Scale factor. Ignored when `width`/`height` are given. |
| `background` | string | Background color; any CSS color form resvg accepts. |

## Error handling

All failures throw `Resvg\Exception`, which extends `RuntimeException`.

```php
try {
    $png = $renderer->render($userSuppliedSvg);
} catch (Resvg\Exception $e) {
    // malformed SVG, invalid size, unparseable background, unencodable output
}
```

Unrecognized option keys and wrongly typed option values raise `ValueError`, following
PHP's own convention for bad argument values.

## Security

SVG is untrusted input in most applications, and resvg is built to handle it:

- Documents are limited to 1,000,000 elements.
- External entity and DTD processing is not performed.
- Referenced resources resolve only through `resourcesDir`, and only for local paths.
- The renderer cannot open sockets or execute scripts.

## Documentation

- [`docs/usage.md`](docs/usage.md) — full API and option reference
- [`docs/installation.md`](docs/installation.md) — build and install detail
- [`examples/`](examples/) — runnable scripts

## License

MIT. Vendored resvg is Apache-2.0 OR MIT; see [NOTICE](NOTICE).
