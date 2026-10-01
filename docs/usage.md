# resvg-php — usage manual

`Resvg\Renderer` renders SVG documents to PNG. It holds a reusable font database and
render configuration, so construct it once and reuse it. `Resvg\Tree` is a parsed
document you can render repeatedly without re-parsing.

## Lifecycle

```php
$renderer = new Resvg\Renderer();   // builds the font database
$png = $renderer->render($svg);     // parse + rasterize

$tree = $renderer->parse($svg);     // parse once
$small = $tree->render(['width' => 64]);
$large = $tree->render(['width' => 512]);
```

A renderer is immutable after construction. Passing options to `render()` never
mutates the renderer; the options apply to that call only. A `Resvg\Tree` is
self-contained — it carries its own font database and stays valid after the
renderer that produced it is released.

`Resvg\Renderer` and `Resvg\Tree` are final and not cloneable. `Tree` has no public
constructor: it is produced by `parse()`/`parseFile()`. Each object owns a native
handle released when the object is garbage collected; there is no `close()` or
`free()` method to call.

## Constructor options

All options are optional. Unknown keys and wrongly typed values raise `ValueError`.

### `fontFamily` — string, default `"Times New Roman"`

The family used when a document sets no `font-family`. The five generic families
(`serif`, `sans-serif`, `cursive`, `fantasy`, `monospace`) resolve the same way the
upstream `resvg` command resolves them.

### `fontSize` — float, default `12.0`

The size used when a document sets no `font-size`.

### `languages` — string or string[], default `"en"`

A comma-separated list (or array) of BCP 47 language tags resolving the
`systemLanguage` conditional attribute. The first entry is the primary language.

### `fontFiles` — string or string[]

Font files loaded into the database on top of the system fonts. Fonts loaded here are
available to every document this renderer processes. A file that fails to load raises
an `E_USER_WARNING` and is skipped — a bad file never fails the constructor, and
`fonts()` reports it.

### `fontDirs` — string or string[]

Directories whose fonts are loaded into the database. Same warn-and-continue
behaviour as `fontFiles`.

### `loadSystemFonts` — bool, default `true`

Whether the system font database is scanned at construction. Turn it off when you
supply every font through `fontFiles`/`fontDirs` — it is the single most expensive
part of constructing a renderer.

### `serifFamily`, `sansSerifFamily`, `cursiveFamily`, `fantasyFamily`, `monospaceFamily` — string

The families the SVG generic keywords (`serif`, `sans-serif`, …) resolve to. Defaults
match the upstream CLI: Times New Roman, Arial, Comic Sans MS, Impact, Courier New.

### `resourcesDir` — string, default none

The base directory resolving relative paths inside the document: `<image href>`
files, external stylesheets, and font references. Without it, the string methods
(`render()`, `measure()`, `parse()`) resolve relative references against the
current working directory, while the `*File()` methods resolve them against the
document's own directory — the same behaviour as the upstream CLI. Set it when
rendering documents that reference local assets. See `docs/security.md` for the
trust implications.

### `confineResources` — bool, default `false`

Requires `resourcesDir`. When true, referenced images are rejected unless they
resolve inside `resourcesDir` — absolute hrefs and `..` escapes are refused. Use it
when rendering untrusted documents. See `docs/security.md`.

### `stylesheet` — string, default none

A CSS stylesheet injected into every document. Its rules override the document's own
attributes, matching normal CSS specificity.

### `dpi` — float, default `96.0`

Resolution used for unit conversion. Applies to documents using absolute units
(`pt`, `pc`, `cm`, `mm`, `in`). The accepted range is 10 to 4000; a value outside it
raises `ValueError`.

### `width` / `height` — int, default unset

The default pixel size for documents that do not declare one and have no `viewBox`.
When a document has no absolute size, resvg needs this to produce a canvas at all;
without it such documents fail with a "no valid size" error.

### `shapeRendering` / `textRendering` / `imageRendering` — string

The rendering hints applied when an element's own property is `auto`. Accepted
values:

- `shapeRendering`: `optimizeSpeed`, `crispEdges`, `geometricPrecision` (default)
- `textRendering`: `optimizeSpeed`, `optimizeLegibility` (default), `geometricPrecision`
- `imageRendering`: `optimizeQuality` (default), `optimizeSpeed`, `smooth`,
  `high-quality`, `crisp-edges`, `pixelated`

## Per-render options

### `width` — int

Target width in pixels. Output height follows the document's aspect ratio.

### `height` — int

Target height in pixels. Output width follows the document's aspect ratio.

Giving both `width` and `height` scales the document to fit inside exactly that
canvas, preserving aspect ratio; the canvas is that size in full.

### `zoom` — float

Scale factor applied to the document's intrinsic size. Ignored when `width` or
`height` is present. An explicit non-positive value raises `ValueError`.

### `background` — string

A color painted behind the document. Any color form the SVG specification accepts:
named CSS colors, `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`. Without it the PNG keeps
transparency.

### `exportArea` — string, default `"drawing"`

Framing for `renderNode()`: `"drawing"` sizes the canvas to the node's own bounding
box; `"page"` draws the node onto a full-document canvas at its position. Matches the
CLI's `--export-area-drawing` and `--export-area-page`.

### `output` — resource or string

Write the encoded PNG to a stream resource or a file path instead of returning it as
a string. The method then returns `true`. This is the path that keeps a large render
out of PHP's memory.

```php
$stream = fopen('/tmp/out.png', 'wb');
$renderer->render($svg, ['output' => $stream]);   // true
fclose($stream);
```

## `parse()` and `parseFile()`

```php
$tree = $renderer->parse($svg);              // from a string
$tree = $renderer->parseFile('/a/b/doc.svg'); // from a file
```

`parseFile()` resolves relative references against the file's own directory unless
`resourcesDir` was set explicitly — the same behaviour as the upstream CLI.

## `Tree` methods

| Method | Returns | Purpose |
|---|---|---|
| `size()` | `['width' => float, 'height' => float]` | The document's intrinsic size in user units. |
| `boundingBox()` | `['x','y','width','height']` or `null` | The drawing's bounding box; `null` when the document draws nothing. |
| `hasNode(string $id)` | `bool` | Whether an element with this `id` exists. |
| `nodeIds()` | `list<string>` | Every `id` in the document, in document order. |
| `render(array $options = [])` | `string\|bool` | Render the whole document. |
| `renderNode(string $id, array $options = [])` | `string\|bool` | Render one element by `id`. |
| `toSvg(array $options = [])` | `string` | Serialize back to SVG through the upstream writer. |

`renderNode()` raises `Resvg\Exception` with code `NO_SUCH_NODE` when the id is
absent, and `ZERO_SIZE_NODE` when the element has an empty bounding box.

### `toSvg()` options

| Option | Type | Default | Effect |
|---|---|---|---|
| `preserveText` | bool | `false` | Keep `<text>` elements instead of converting text to paths. |
| `idPrefix` | string | — | Prefix added to every `id` attribute. |
| `indent` | string\|int | `4` | `"none"`, `"tabs"`, or `0`–`4` spaces. |
| `attrsIndent` | string\|int | `"none"` | Same accepted set as `indent`. |
| `coordinatesPrecision` | int | `8` | Decimal precision for coordinates (2–8). |
| `transformsPrecision` | int | `8` | Decimal precision for transforms (2–8). |
| `useSingleQuote` | bool | `false` | Use `'` instead of `"` for attribute delimiters. |

## `fonts()`

```php
$renderer->fonts();   // ['DejaVu Sans' => '/usr/share/fonts/.../DejaVuSans.ttf', ...]
```

The loaded faces as a `family => path` map. Font files that failed to load raise an
`E_USER_WARNING` as they are reported here and are not listed.

## `measure()`

```php
$size = $renderer->measure($svg, ['width' => 512]);
// ['width' => 512, 'height' => 342]
```

Returns the pixel dimensions a render with the same options would produce, without
rasterizing. Accepts `width`, `height`, and `zoom` only — the raster-only options
(`background`, `exportArea`, `output`) raise `ValueError` rather than being ignored.

## `version()`

```php
Resvg\Renderer::version();  // "0.2.0+resvg.0.48.1"
```

The extension version plus the vendored resvg version. Include it in bug reports.

## Error model

| Condition | Result |
|---|---|
| Malformed or non-UTF-8 SVG | `Resvg\Exception` |
| Document with no determinable size | `Resvg\Exception` ("no valid size") |
| Element count above the 1,000,000 limit | `Resvg\Exception` |
| No node with the requested `id` | `Resvg\Exception` (`NO_SUCH_NODE`) |
| Render larger than `resvg.max_render_pixels` | `Resvg\Exception` (`TOO_LARGE`) |
| Document larger than `resvg.max_input_size` | `Resvg\Exception` |
| Invalid `background` value | `Resvg\Exception` |
| Unknown or wrongly typed option | `ValueError` |
| `dpi` outside 10..4000, `fontSize` outside 1..192, `zoom` ≤ 0 | `ValueError` |
| `measure()` given `background`, `exportArea`, or `output` | `ValueError` |
| `confineResources` without `resourcesDir` | `ValueError` |
| Font file that fails to load | `E_USER_WARNING`, loading continues |

`Resvg\Exception` extends `RuntimeException`, and every status code is a class
constant on it (`PARSE_FAILED`, `NOT_UTF8`, `INVALID_SIZE`, `ELEMENTS_LIMIT`,
`MALFORMED_GZIP`, `SVGZ_DISABLED`, `NO_SUCH_NODE`, `ZERO_SIZE_NODE`,
`ENCODE_FAILED`, `ALLOCATION_FAILED`, `INVALID_ARGUMENT`, `INTERNAL`, `TOO_LARGE`),
matching `getCode()`.

```php
try {
    $png = $renderer->render($svg);
} catch (Resvg\Exception $e) {
    if ($e->getCode() === Resvg\Exception::TOO_LARGE) {
        // size to a smaller canvas
    }
}
```

A panic inside the renderer cannot cross into PHP: it is contained and reported as a
`Resvg\Exception` with a sanitized message. No internal detail escapes through
exception messages.

## Performance notes

- Construct the renderer once per request (or per service lifetime). The constructor
  scans system fonts; `render()` calls after the first parse a document and rasterize
  it with no repeated font setup.
- Prefer `parse()` + `Tree::render()` when the same document is rendered more than
  once: parsing happens once and every render reuses the tree.
- Rendering is single-threaded per call, like the upstream library. Renders across
  concurrent PHP workers scale with cores, and on ZTS builds concurrent threads in
  one process can render independently — no shared mutable state exists between
  calls.
- The PNG is produced by the same encoder the upstream `resvg` tool uses; there is no
  re-encode step between the raster surface and the returned bytes.
- For large images, prefer the `output` sink over the returned string: the PNG is
  written straight out instead of copied into a PHP string.

### Benchmark ratchet

`tools/benchmark.php` measures throughput (ops/sec) and real OS memory
(`VmRSS`/`VmHWM`) for representative workloads. The repository tracks a recorded
baseline at `tests/benchmark/baseline.json`; compare a run against it locally:

```sh
php -n -d extension=build/resvg-php8.3.so tools/benchmark.php \
    --iterations=500 --compare=tests/benchmark/baseline.json
```

A comparison exits non-zero when any case regresses past the threshold (default
15%), and refuses to run at all when the baseline was recorded on a different
architecture — throughput baselines are not comparable across ISAs. Absolute
numbers are host-relative — the ratchet compares like-for-like on the same
machine, which is why CI does not run it. Record a fresh baseline after hardware
changes with `--record=tests/benchmark/baseline.json`.
