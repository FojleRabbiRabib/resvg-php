# Changelog

All notable changes to resvg-php are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
Semantic Versioning.

## [Unreleased]

### Added

- `Resvg\Renderer` with `render()`, `measure()`, and `version()`, backed by a vendored
  resvg 0.48.1 core statically linked into a self-contained `.so`.
- Constructor options: `fontFamily`, `fontSize`, `languages`, `fontFiles`,
  `resourcesDir`, `stylesheet`, `dpi`, `width`, `height`.
- Per-render options: `width`, `height`, `zoom`, `background`.
- `Resvg\Exception` (extends `RuntimeException`) for renderer failures.
- ELF hardening gates (RELRO, BIND_NOW, non-executable stack, no rpath) and symbol
  isolation exporting only `get_module`.
- Render-fidelity gate: byte-identical output versus the upstream `resvg` CLI across
  the fixture set, on PHP 8.3, 8.4, and 8.5.
