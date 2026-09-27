# resvg-php — usage manual

`Resvg\Renderer` renders SVG documents to PNG. It holds a reusable font database and
render configuration, so construct it once and reuse it.

## Lifecycle

```php
$renderer = new Resvg\Renderer();   // builds the font database
$png = $renderer->render($svg);     // parse + rasterize
```

A renderer is immutable after construction. Passing options to `render()` never
mutates the renderer; the options apply to that call only.

`Resvg\Renderer` is final and not cloneable. The object owns a native handle which is
released when the object is garbage collected; there is no `close()` or `free()`
method to call.

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
available to every document this renderer processes. Loading a file that is not a
valid font logs a warning and continues — a bad file never fails the constructor.

### `resourcesDir` — string, default none

The base directory resolving relative paths inside the document: `<image href>`
files, external stylesheets, and font references. Without it, relative references
resolve against the current working directory. Set it when rendering files that
reference local assets.

### `stylesheet` — string, default none

A CSS stylesheet injected into every document. Its rules override the document's own
attributes, matching normal CSS specificity.

### `dpi` — float, default `96.0`

Resolution used for unit conversion. Applies to documents using absolute units
(`pt`, `pc`, `cm`, `mm`, `in`). The accepted range is 10 to 4000.

### `width` / `height` — int, default unset

The default pixel size for documents that do not declare one and have no `viewBox`.
When a document has no absolute size, resvg needs this to produce a canvas at all;
without it such documents fail with a "no valid size" error.

## Per-render options

### `width` — int

Target width in pixels. Output height follows the document's aspect ratio.

### `height` — int

Target height in pixels. Output width follows the document's aspect ratio.

Giving both `width` and `height` scales the document to fit inside exactly that
canvas, preserving aspect ratio; the canvas is that size in full.

### `zoom` — float

Scale factor applied to the document's intrinsic size. Ignored when `width` or
`height` is present.

### `background` — string

A color painted behind the document. Any color form the SVG specification accepts:
named CSS colors, `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`. Without it the PNG keeps
transparency.

## `measure()`

```php
$size = $renderer->measure($svg, ['width' => 512]);
// ['width' => 512, 'height' => 342]
```

Returns the pixel dimensions a render with the same options would produce, without
rasterizing. Use it to lay out a canvas or validate a size before spending the render.

## `version()`

```php
Resvg\Renderer::version();  // "0.1.0+resvg.0.48.1"
```

The extension version plus the vendored resvg version. Include it in bug reports.

## Error model

| Condition | Result |
|---|---|
| Malformed or non-UTF-8 SVG | `Resvg\Exception` |
| Document with no determinable size | `Resvg\Exception` ("no valid size") |
| Element count above the 1,000,000 limit | `Resvg\Exception` |
| Invalid `background` value | `ValueError` |
| Unknown or wrongly typed option | `ValueError` |

`Resvg\Exception` extends `RuntimeException`, so an existing
`catch (RuntimeException $e)` keeps working.

A panic inside the renderer cannot cross into PHP: it is contained and reported as a
`Resvg\Exception` with a sanitized message. No internal detail escapes through
exception messages.

## Performance notes

- Construct the renderer once per request (or per service lifetime). The constructor
  scans system fonts; `render()` calls after the first parse a document and rasterize
  it with no repeated font setup.
- Rendering is single-threaded per call, like the upstream library. Renders across
  concurrent PHP workers scale with cores.
- The PNG is produced by the same encoder the upstream `resvg` tool uses; there is no
  re-encode step between the raster surface and the returned bytes.
