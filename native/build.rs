//! Build script: injects the package version from the PHP module header so the
//! shim's composite version string is derived from the single source of truth
//! (`php_resvg.h`) instead of a second hand-maintained literal.

use std::env;
use std::fs;
use std::path::Path;

fn main() {
    // The shim crate sits at native/; the module header is one level up.
    let header = Path::new(env!("CARGO_MANIFEST_DIR")).join("../php_resvg.h");
    println!("cargo:rerun-if-changed={}", header.display());

    let source = fs::read_to_string(&header).unwrap_or_else(|error| {
        panic!("build.rs: cannot read {}: {error}", header.display());
    });

    let version = source
        .lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix(r#"#define PHP_RESVG_VERSION ""#))
        .and_then(|rest| rest.split('"').next())
        .unwrap_or_else(|| {
            panic!(
                "build.rs: PHP_RESVG_VERSION not found in {}",
                header.display()
            )
        });

    if version.is_empty() {
        panic!("build.rs: PHP_RESVG_VERSION is empty");
    }

    println!("cargo:rustc-env=RSP_PACKAGE_VERSION={version}");
}
