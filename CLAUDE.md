# CLAUDE.md

Guidance for working in this repository.

## What this is

`resvg-php` renders SVG to PNG from PHP, in-process, using a vendored build of
[resvg](https://github.com/linebender/resvg) (Rust, Apache-2.0 OR MIT) statically
linked into a self-contained PHP extension.

## Architecture

Three layers, one artifact:

1. **Vendored renderer** — pinned resvg source in `vendor-src/` (fetched and
   hash-verified by the build; never committed). Upstream's own `c-api` crate stops at
   raw premultiplied RGBA and cannot encode PNG, so it is not used directly.
2. **Rust shim** (`native/`) — wraps the `resvg` crate on the CLI's own
   render/encode path and exposes a flat C ABI. Options are a persistent handle
   because building the font database is expensive and must not repeat per render.
3. **PHP extension** (sources at the repository root) — pure C. Owns one shim
   handle per `Resvg\Renderer` object and marshals options. Linked against the
   shim's static archive into a single `.so` that exports only `get_module`.

## Commands

```sh
tools/build.sh 8.3            # build + fidelity gate for one ABI (8.3 | 8.4 | 8.5)
tools/build.sh 8.4 SKIP_GATE=1
tools/build-oracle.sh         # build the upstream resvg CLI (the gate's oracle)
tools/test-fidelity.sh build/resvg-php8.3.so
tools/test-phpt.php build/resvg-php8.3.so

vendor/bin/phpcs
vendor/bin/phpstan analyse
clang-format-14 -i *.c *.h
cargo fmt --manifest-path native/Cargo.toml
cargo clippy --manifest-path native/Cargo.toml -- -D warnings
```

## The fidelity gate

This is the project's correctness bar, and it is not negotiable: for every fixture in
`tests/fixtures/`, the extension's PNG output must be **byte-identical** to the output
of the upstream `resvg` CLI built from the same vendored source. Any drift is an
integration bug (wrong option mapping, alpha handling, font selection) — diagnose it
to root cause; never loosen the comparison.

PHP-facing defaults must equal library defaults so the comparison stays like-for-like.

## Conventions

- **Zero AI attribution** in commits or PRs — no `Co-Authored-By` trailer, no
  `Generated with` footer.
- Commit messages: Conventional Commits with scope, three blocks (title, one bullet
  block, optional unlabeled note). Scopes: `resvg`, `ext`, `ci`, `installer`,
  `release`, `docs`.
- Commits are **local**; never push or trigger remote workflows without an explicit
  request.
- **Planning and design notes live in the project root, untracked** — never committed,
  never added to `.gitignore`. Product documentation lives in `docs/` and is committed.
  The repo is public; treat every committed file as publishable.
- Greenfield code: no compatibility shims, aliases, or "keep the old name working"
  paths. Real SVG-spec behaviour is always implemented; internal compat scaffolding
  never is.

## Requirements

Building needs Rust ≥ 1.85 (resvg 0.48.x is edition 2024). The pinned toolchain lives
at `~/.cargo/bin`; a distro `cargo` may be older and will not build the shim.
