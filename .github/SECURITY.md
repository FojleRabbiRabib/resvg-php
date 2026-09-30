# Security Policy

## Supported versions

The extension is validated on PHP 8.3, 8.4, and 8.5 (NTS builds). Security fixes
land on `main` and ship in the next release; there are no long-lived support
branches yet.

## Reporting a vulnerability

**Do not open a public issue for a security report.**

Use GitHub's private vulnerability reporting on this repository
(Security → Report a vulnerability). Reports are triaged as they arrive; you
will get a response with an assessment and, once confirmed, a fix timeline.

Include what you can of: the affected version (`Resvg\Renderer::version()`),
a minimal document that triggers the issue, and the deployment posture
(trusted or untrusted SVG sources, `confineResources` on or off).

## What is in scope

- Malformed or adversarial SVG causing a crash, hang, unbounded allocation, or
  information disclosure.
- The reference-resolution surface: `<image href>` reading files the caller
  did not intend to expose, symlink or `..` escapes past `confineResources`.
- The INI ceilings (`resvg.max_input_size`, `resvg.max_render_pixels`)
  failing open or being bypassable.
- Native faults: panics, unwinds, or use-after-free crossing the FFI boundary
  into PHP.
- Font-file parsing exposed to attacker-supplied fonts.

## What is out of scope

- Rendering results that differ aesthetically from another renderer.
- Denial of service through `memory_limit` exhaustion under PHP's own
  accounting (the INI ceilings exist because of this; tune them for your
  deployment).
- Vulnerabilities in PHP itself, the Rust toolchain, or upstream `resvg` that
  reproduce identically in the upstream `resvg` CLI — those belong upstream
  (https://github.com/linebender/resvg/security), though we appreciate a heads-up.

## Guidance for untrusted input

Before rendering documents from untrusted sources, read
[docs/security.md](docs/security.md): enable `confineResources` with a
`resourcesDir`, size both INI ceilings to the smallest images your
application needs, and never take font paths from untrusted input.
