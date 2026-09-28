# Changelog

All notable changes to resvg-php are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
Semantic Versioning.

## [Unreleased]

### Added

- `Resvg\Renderer` with `render()`, `measure()`, and `version()`, backed by a vendored
  resvg 0.48.1 core statically linked into a self-contained `.so`.
- `Resvg\Tree`: parse once, render many. Carries its own font database, so it may
  outlive the renderer that produced it; node-addressed through `hasNode()`,
  `nodeIds()`, and `renderNode()`, and serializable back to SVG through `toSvg()`.
- `Resvg\Exception` (extends `RuntimeException`) for renderer failures, with the
  ABI status codes exposed as class constants (`PARSE_FAILED`, `NO_SUCH_NODE`,
  `TOO_LARGE`, …) and the parser's own detail appended to the message where
  upstream produced one.
- Constructor options: `fontFamily`, `fontSize`, `languages`, `fontFiles`,
  `fontDirs`, `resourcesDir`, `stylesheet`, `dpi`, `width`, `height`,
  `loadSystemFonts`, `confineResources`, `serifFamily`, `sansSerifFamily`,
  `cursiveFamily`, `fantasyFamily`, `monospaceFamily`, `shapeRendering`,
  `textRendering`, `imageRendering`.
- Per-render options: `width`, `height`, `zoom`, `background`, `exportArea`, and
  `output` (stream resource or path) for delivering a render without materializing
  the PNG in PHP memory. Writer options on `toSvg()`: `preserveText`, `idPrefix`,
  `indent`, `attrsIndent`, `coordinatesPrecision`, `transformsPrecision`,
  `useSingleQuote`.
- `Renderer::fonts()` reporting loaded faces as `family => path`, with a
  `E_USER_WARNING` per font file that failed to load.
- `Resvg\Exception::TOO_LARGE` (code 14) for renders whose produced size exceeds
  `resvg.max_render_pixels`.
- Resource ceilings `resvg.max_input_size` and `resvg.max_render_pixels`, enforced
  before the input copy and on the produced render size respectively.
- Opt-in reference confinement via `confineResources` + `resourcesDir`: absolute
  hrefs and any path escaping the root are rejected.
- ELF hardening gates (RELRO, BIND_NOW, non-executable stack, no rpath) and symbol
  isolation exporting only `get_module`.
- PNG fidelity gate: byte-identical output versus the upstream `resvg` CLI, over
  option-set rows, on PHP 8.3, 8.4, and 8.5.
- toSvg fidelity gate: byte-identical output versus the upstream `usvg` CLI over
  the full `WriteOptions` surface and its boundary values.
- Valgrind memory gate over lifecycle churn, error paths, and fork churn.

### Changed

- `render()`, `renderFile()`, `Tree::render()`, and `renderNode()` return
  `string|bool`: the PNG string normally, `true` when an `output` sink received it.
- `parseFile()`/`renderFile()`/`measureFile()` resolve `resourcesDir` to the file's
  own canonical directory when the caller set none, mirroring the CLI.
- `confineResources` requires `resourcesDir`; the two are rejected together with a
  `ValueError` when the root is missing.
- `dpi` is validated to 10..4000 and `fontSize` to 1..192, matching the CLI; an
  explicit non-positive `zoom` raises `ValueError` instead of meaning "unset".

### Security

- `resvg.max_render_pixels` is enforced on the size a render actually produces —
  after fit-to resolution — so `zoom`, single-side fits, default-size documents,
  and node exports are all bounded, with the product computed in 64-bit.
- `resvg.max_input_size` is enforced before the document is copied into memory,
  and oversized `*File()` reads report the ceiling rather than a generic failure.
- Node-export rendering paints only the requested node, matching `--export-id`,
  so sibling content outside the exported node is not composited in.
