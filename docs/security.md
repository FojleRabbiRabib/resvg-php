# resvg-php — security manual

Threat model, resource limits, and safe-usage guidance for embedding `resvg-php`
in an application that renders untrusted SVG.

## Threat model

Documents are untrusted input. The typical deployment renders SVG produced by
another party — user uploads, an API response, a template engine — inside a
long-lived PHP worker that also serves other requests. The risks worth designing
against are:

- **Resource amplification.** A small document that expands into a huge image or
  an enormous amount of parsing work. Handled by the ceilings below.
- **Reading files the caller should not reach.** An SVG can reference local files
  through `<image href>`. Handled by the reference-resolution rules below.
- **Parser exploitation.** Malformed XML, gzip bombs, pathological structures.
  Handled by inheriting resvg's own hardening.
- **Native faults.** A crash or unwind inside the renderer taking the PHP worker
  down. Handled at the FFI boundary.

Rendering is local: resvg performs no network access, and neither does this
extension.

## Inherited resvg hardening

The vendored renderer already provides, and this extension does not weaken:

- **No DTD or external entity processing.** Billion-laughs-style entity
  expansion has no path into the parser.
- **A 1,000,000-element limit** on a single document
  (`crates/usvg/src/parser/mod.rs`), surfaced as `Resvg\Exception` with code
  `ELEMENTS_LIMIT`.
- **No script execution** and **no network access** — SVG scripts are ignored,
  and non-path `href` strings (including `http://…`) are skipped because they do
  not name a local file. There is no SSRF surface: a document cannot make the
  renderer fetch anything.

## Resource ceilings

Both are INI settings, operator-tunable, visible in `phpinfo()`, and enforced on
every render path including the streaming (`output`) path.

| Setting | Default | Bounds |
|---|---|---|
| `resvg.max_input_size` | 16777216 (16 MiB) | bytes of SVG input accepted |
| `resvg.max_render_pixels` | 67108864 (64 Mpx) | `width × height` of a render |

`resvg.max_render_pixels` is checked against the size a render will **actually
produce** — after `zoom`, `width`/`height`, or node-export scaling has been
applied — not merely the option values a caller passed. The product is computed
in 64-bit, so it cannot wrap past the ceiling. Exceeding it raises
`Resvg\Exception` with code `TOO_LARGE`.

`resvg.max_input_size` is checked **before** the document is read into memory, so
an oversized file is rejected without being buffered. A `*File()` method reports
an oversized document as exactly that, not as a generic read failure.

Both fail closed: over the ceiling is an exception, never a truncated output.

```ini
; php.ini — tighten for untrusted input on small workers
resvg.max_input_size = 1048576
resvg.max_render_pixels = 8388608   ; 4K × 4K
```

## Referenced files

An SVG may reference local files:

```xml
<image href="logo.png"/>
<image href="/etc/passwd"/>   <!-- absolute path -->
<image href="../../secrets.png"/>
```

**Default behaviour is permissive, and that is deliberate.** A relative href
resolves against `resourcesDir` (or, for `parseFile()`/`renderFile()`/
`measureFile()`, the document's own directory when `resourcesDir` was not set),
and an absolute path is used as given. This matches the upstream `resvg` CLI
byte for byte, which is the project's correctness contract — see
`docs/usage.md`.

That default is wrong for untrusted documents: any file readable by the PHP
process could be pulled into the output, and the presence or absence of an image
is an oracle about the filesystem.

### Confinement

`confineResources => true` (which requires `resourcesDir`) replaces the default
resolver with a confined one:

- **Absolute hrefs are rejected outright.**
- The candidate is resolved through `canonicalize()`, so `..` segments and
  symlinks cannot escape: the resolved path must still be inside `resourcesDir`.
- The file is accepted only if its bytes sniff as a format resvg supports
  (PNG, JPEG, GIF, WebP, or a nested SVG) — matching upstream's own format
  sniffing, so confinement accepts exactly what default mode accepts.

```php
$renderer = new Resvg\Renderer([
    'resourcesDir'     => '/var/www/svg-assets',
    'confineResources' => true,
]);
```

The fidelity gate always runs in default (parity) mode; this confinement mode is
for applications rendering untrusted documents, where dropping a reference is
the correct behaviour and byte parity with the CLI is not the goal.

## Font input

Fonts are **trusted input**. resvg bundles no fonts; the database is system
fonts plus whatever `fontFiles`/`fontDirs` add, and those files are parsed by the
in-process font parser. An application that lets users supply font files is
exposing that parser to them — do not take font paths from untrusted input.

A container with no installed fonts renders text as blank unless fonts are
supplied. `Renderer::fonts()` lists what actually loaded, and a file that fails
to load raises an `E_USER_WARNING` and is skipped rather than failing the
constructor.

## Native faults

A panic inside the renderer cannot reach PHP. Every exported call that can fail
is wrapped so an unwind is contained and reported as `Resvg\Exception` with code
`INTERNAL` and a sanitized message; buffers allocated across the boundary are
released before the call returns. No internal paths, symbols, or Rust
backtraces appear in exception messages.

## Deployment guidance

- Prefer the latest PHP patch release; this extension supports 8.3/8.4/8.5 NTS.
- Render untrusted documents with `confineResources` on, and with ceilings sized
  to the smallest images your application actually needs.
- If workers are long-lived, construct one `Resvg\Renderer` per worker and reuse
  it — a renderer holds a font database, and re-scanning fonts per request is
  the most expensive thing the extension does.
- The extension is validated on NTS builds only. ZTS is not yet claimed.
