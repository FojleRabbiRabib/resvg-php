# resvg-php

[![CI](https://github.com/FojleRabbiRabib/resvg-php/actions/workflows/ci.yml/badge.svg)](https://github.com/FojleRabbiRabib/resvg-php/actions/workflows/ci.yml)

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

- PHP 8.3, 8.4, or 8.5, non-thread-safe (NTS) or thread-safe (ZTS) builds
- Linux x86-64 or aarch64 (glibc or musl), or macOS arm64
- For building from source: Rust 1.85 or newer, and a PHP development toolchain

ZTS builds are validated: the extension is built and gated under the thread-safe
SAPI, and a multi-threaded stress harness runs clean under Valgrind Helgrind and
Memcheck.

## Installation

### PIE (recommended)

[PIE](https://github.com/php/pie) resolves the package and installs the matching
prebuilt binary for your PHP version, falling back to a source build when no
prebuilt asset matches:

```sh
pie install resvg-php/resvg
```

### Prebuilt

Download the assets for your PHP ABI from the releases page. Each release carries
a PIE archive per ABI (`php_resvg-<version>_php8.N-<arch>-linux-glibc-nts.zip`
wrapping `resvg.so`), a bare `resvg-php8.N-linux-<arch>.so` for direct download,
`SHA256SUMS`, and cosign signature bundles. Verify and add it to your `php.ini`:

```sh
sha256sum -c SHA256SUMS
cosign verify-blob --bundle resvg-php8.3-linux-x86_64.so.bundle \
    resvg-php8.3-linux-x86_64.so
```

```ini
extension=/path/to/resvg-php8.3-linux-x86_64.so
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

### Parse once, render many

`parse()` returns a `Resvg\Tree` — a parsed document you can render repeatedly, at
different sizes and backgrounds, without re-parsing.

```php
$tree = $renderer->parse(file_get_contents('badge.svg'));

$small = $tree->render(['width' => 64]);
$large = $tree->render(['width' => 512, 'background' => '#ffffff']);
```

A tree is self-contained: it holds its own font database, so it stays valid even if
the renderer that produced it is gone.

### Rendering one node

`renderNode()` renders a single element by its `id`, with the same semantics as the
upstream `resvg --export-id`: only that element is painted, sized to its own
bounding box.

```php
$tree->renderNode('chart-legend');
$tree->renderNode('chart-legend', ['exportArea' => 'page']);   // on a full-page canvas
```

`nodeIds()` lists every `id` in the document and `hasNode()` tests one.

### Writing SVG back out

`toSvg()` serializes the parsed tree through the upstream writer — useful for
normalizing a document or inspecting how resvg resolved it.

```php
$normalized = $tree->toSvg();                          // text converted to paths
$withText   = $tree->toSvg(['preserveText' => true]);  // keep <text> elements
$pretty     = $tree->toSvg(['indent' => 'tabs']);
```

### Streaming large renders

For a large image, pass an `output` sink and the PNG is written straight to it
rather than returned as a string. The method returns `true` in that case.

```php
$stream = fopen('/var/www/out.png', 'wb');
$renderer->render($bigSvg, ['output' => $stream]);   // true
fclose($stream);

$renderer->render($bigSvg, ['output' => '/var/www/out.png']);   // path also accepted
```

### Confining referenced files

SVG can reference external images. By default a relative reference resolves against
`resourcesDir` (or the file's own directory for the `*File()` methods) and an
absolute path is allowed — which matters when documents are untrusted. Set
`confineResources` to reject anything outside the root:

```php
$renderer = new Resvg\Renderer([
    'resourcesDir'     => '/var/www/svg-assets',
    'confineResources' => true,   // absolute hrefs and `..` escapes are refused
]);
```

See [`docs/security.md`](docs/security.md) for the full threat model.

### Version

```php
Resvg\Renderer::version();   // "0.2.0+resvg.0.48.1"
```

## Options reference

Constructor options:

| Option | Type | Default | Description |
|---|---|---|---|
| `fontFamily` | string | `"Times New Roman"` | Family used when the SVG sets no `font-family`. |
| `fontSize` | float 1..192 | `12.0` | Size used when the SVG sets no `font-size`. |
| `serifFamily`, `sansSerifFamily`, `cursiveFamily`, `fantasyFamily`, `monospaceFamily` | string | `"Times New Roman"` etc. | Families the SVG generic keywords resolve to. |
| `languages` | string\|string[] | `"en"` | Resolves the `systemLanguage` attribute. |
| `fontFiles` | string\|string[] | — | Extra font files to load. |
| `fontDirs` | string\|string[] | — | Directories of fonts to load. |
| `loadSystemFonts` | bool | `true` | Scan the system font database. |
| `resourcesDir` | string | — | Base directory for relative paths in the SVG. |
| `confineResources` | bool | `false` | Refuse references outside `resourcesDir`. |
| `stylesheet` | string | — | CSS injected into every document, overriding its own rules. |
| `dpi` | float 10..4000 | `96.0` | Affects unit conversion. |
| `width` | int | — | Default width for documents without absolute dimensions. |
| `height` | int | — | Default height for documents without absolute dimensions. |
| `shapeRendering` | string | `"geometricPrecision"` | `optimizeSpeed`, `crispEdges`, `geometricPrecision`. |
| `textRendering` | string | `"optimizeLegibility"` | `optimizeSpeed`, `optimizeLegibility`, `geometricPrecision`. |
| `imageRendering` | string | `"optimizeQuality"` | `optimizeQuality`, `optimizeSpeed`, `smooth`, `high-quality`, `crisp-edges`, `pixelated`. |

Per-render options:

| Option | Type | Description |
|---|---|---|
| `width` | int | Target width in pixels. |
| `height` | int | Target height in pixels. |
| `zoom` | float | Scale factor. Ignored when `width`/`height` are given. |
| `background` | string | Background color; any CSS color form resvg accepts. |
| `exportArea` | string | `"drawing"` (default) or `"page"` — node-export framing. |
| `output` | resource\|string | Write the PNG here; the method then returns `true`. |

`toSvg()` options: `preserveText`, `idPrefix`, `indent` (`"none"`, `"tabs"`, or `0`–`4`),
`attrsIndent`, `coordinatesPrecision` (2–8), `transformsPrecision` (2–8), `useSingleQuote`.

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
- The renderer cannot open sockets or execute scripts.
- `resvg.max_input_size` bounds the document size and `resvg.max_render_pixels`
  bounds the rendered pixel count; both are enforced before the expensive step and
  fail closed with `Resvg\Exception`.
- Referenced images are **not** confined by default: a relative href resolves
  against `resourcesDir`, but an absolute path is allowed. Set `confineResources`
  to reject absolute hrefs and any path escaping the root.

See [`docs/security.md`](docs/security.md) for the threat model and deployment
guidance.

## Documentation

- [`docs/usage.md`](docs/usage.md) — full API and option reference
- [`docs/security.md`](docs/security.md) — threat model and safe-usage guidance
- [`docs/installation.md`](docs/installation.md) — build and install detail
- [`examples/`](examples/) — runnable scripts

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). The NOTICE file carries the
attribution the license requires; redistributions must preserve it. Vendored resvg is
Apache-2.0 OR MIT.
