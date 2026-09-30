// resvg-php Rust shim: the resvg crate behind a flat C ABI.
//
// Copyright 2026 Fojle Rabbi (Rabib)
// SPDX-License-Identifier: Apache-2.0
//
// The upstream `resvg-capi` crate stops at raw premultiplied RGBA and cannot encode
// PNG, so byte-for-byte parity with the `resvg` CLI is impossible through it. This
// shim wraps the `resvg` crate directly on the CLI's own render/encode path
// (`resvg::render` + `tiny_skia::Pixmap::encode_png`) and emits a complete PNG.
//
// Options are a persistent handle because building the font database scans the
// system and is far too expensive to repeat per render; the PHP object owns one
// handle for its lifetime, mirroring how the CLI parses its fonts once.
//
// Parity references (kept in lockstep with the vendored pin):
//   crates/resvg/src/main.rs  — FitTo, render_svg, --export-id, load_fonts
//   crates/usvg/src/main.rs   — writer options and their defaults
// Those files define CLI-compatible behaviour; a parity change upstream must be
// reflected here in the same bump.

use std::ffi::{c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::slice;
use std::sync::Arc;

// ---------------------------------------------------------------------------
// Status codes — the ABI contract. Keep in lockstep with resvg_internal.h and
// the PHP constants in resvg.stub.php; the sets must be identical.
// ---------------------------------------------------------------------------

pub const RSP_OK: i32 = 0;
pub const RSP_ERROR_NULL_POINTER: i32 = 1;
pub const RSP_ERROR_UTF8: i32 = 2;
pub const RSP_ERROR_INVALID_SIZE: i32 = 3;
pub const RSP_ERROR_PARSING: i32 = 4;
pub const RSP_ERROR_ALLOCATION: i32 = 5;
pub const RSP_ERROR_ENCODE: i32 = 6;
pub const RSP_ERROR_INTERNAL: i32 = 7;
pub const RSP_ERROR_INVALID_ARGUMENT: i32 = 8;
pub const RSP_ERROR_NO_SUCH_NODE: i32 = 9;
pub const RSP_ERROR_ZERO_SIZE_NODE: i32 = 10;
pub const RSP_ERROR_ELEMENTS_LIMIT: i32 = 11;
pub const RSP_ERROR_MALFORMED_GZIP: i32 = 12;
pub const RSP_ERROR_SVGZ_DISABLED: i32 = 13;
pub const RSP_ERROR_TOO_LARGE: i32 = 14;

// Rendering-hint discriminants, matching usvg's enum declaration order
// (crates/usvg/src/tree/mod.rs). The PHP layer maps names onto these numbers.
const SHAPE_OPTIMIZE_SPEED: i32 = 0;
const SHAPE_CRISP_EDGES: i32 = 1;
const SHAPE_GEOMETRIC_PRECISION: i32 = 2;

const TEXT_OPTIMIZE_SPEED: i32 = 0;
const TEXT_OPTIMIZE_LEGIBILITY: i32 = 1;
const TEXT_GEOMETRIC_PRECISION: i32 = 2;

const IMAGE_OPTIMIZE_QUALITY: i32 = 0;
const IMAGE_OPTIMIZE_SPEED: i32 = 1;
const IMAGE_SMOOTH: i32 = 2;
const IMAGE_HIGH_QUALITY: i32 = 3;
const IMAGE_CRISP_EDGES: i32 = 4;
const IMAGE_PIXELATED: i32 = 5;

// Indent discriminants, matching xmlwriter::Indent.
const INDENT_NONE: i32 = -1;
const INDENT_TABS: i32 = -2;

// The last failure detail, per thread. Borrowed by `resvg_php_last_error`.
// Every exported function clears it on entry and every failure branch sets it,
// so a stale message can never be read after a later call.
thread_local! {
    static LAST_ERROR: std::cell::RefCell<std::ffi::CString> =
        std::cell::RefCell::new(std::ffi::CString::new("").unwrap());
}

fn set_last_error(message: &str) {
    let sanitized: String = message
        .chars()
        .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
        .collect();
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = std::ffi::CString::new(sanitized)
            .unwrap_or_else(|_| std::ffi::CString::new("error detail unavailable").unwrap());
    });
}

fn clear_last_error() {
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = std::ffi::CString::new("").unwrap();
    });
}

/// A reusable parse/render configuration: font database, DPI, language list,
/// stylesheet, rendering hints, and the default sizing applied when a render
/// specifies no explicit size.
///
/// The fields are the construction recipe rather than a built `usvg::Options`:
/// `usvg::Options` owns non-`Clone` resolver closures, so a per-parse
/// `resources_dir` (the `*File()` paths resolve the file's own directory when
/// the caller set none) can only be applied by rebuilding the options around
/// the shared font database. That rebuild is cheap — `fontdb` is an `Arc` —
/// and the recipe is immutable, so no parse can observe another's state.
pub struct RspOptions {
    fontdb: Arc<usvg::fontdb::Database>,
    resources_dir: Option<PathBuf>,
    confine_resources: bool,
    dpi: f32,
    font_family: String,
    font_size: f32,
    languages: Vec<String>,
    shape_rendering: usvg::ShapeRendering,
    text_rendering: usvg::TextRendering,
    image_rendering: usvg::ImageRendering,
    default_size: usvg::Size,
    style_sheet: Option<String>,
    /// Font files whose load failed during construction; reported with
    /// per-path status by [`resvg_php_options_fonts`].
    font_failures: Vec<String>,
}

impl RspOptions {
    /// Builds the `usvg::Options` for one parse: the recipe plus the effective
    /// `resources_dir` (the per-parse override when one was passed, the
    /// constructor value otherwise). Confinement roots at that same directory,
    /// mirroring the CLI's resolution order.
    fn build(&self, resources_dir: Option<PathBuf>) -> usvg::Options<'static> {
        let mut opt = usvg::Options::<'static> {
            resources_dir,
            dpi: self.dpi,
            font_family: self.font_family.clone(),
            font_size: self.font_size,
            languages: self.languages.clone(),
            shape_rendering: self.shape_rendering,
            text_rendering: self.text_rendering,
            image_rendering: self.image_rendering,
            default_size: self.default_size,
            style_sheet: self.style_sheet.clone(),
            fontdb: Arc::clone(&self.fontdb),
            ..Default::default()
        };
        if self.confine_resources {
            let root = opt
                .resources_dir
                .clone()
                .unwrap_or_else(|| PathBuf::from("."));
            opt.image_href_resolver.resolve_string = confined_string_resolver(root);
        }
        opt
    }
}

/// A parsed document. Owns its font database (via `usvg::Tree`), so it may
/// outlive the options handle that produced it.
pub struct RspTree {
    tree: usvg::Tree,
}

#[derive(Clone, Copy)]
enum FitTo {
    Original,
    Width(u32),
    Height(u32),
    Size(u32, u32),
    Zoom(f32),
}

/// Where a node export measures from, mirroring the CLI's export-area flags.
#[derive(Clone, Copy, PartialEq)]
enum ExportArea {
    Drawing,
    Page,
}

impl FitTo {
    // Mirrors crates/resvg/src/main.rs `FitTo::fit_to_size`.
    fn fit_to_size(&self, size: tiny_skia::IntSize) -> Option<tiny_skia::IntSize> {
        match *self {
            FitTo::Original => Some(size),
            FitTo::Width(w) => size.scale_to_width(w),
            FitTo::Height(h) => size.scale_to_height(h),
            FitTo::Size(w, h) => tiny_skia::IntSize::from_wh(w, h).map(|s| size.scale_to(s)),
            FitTo::Zoom(z) => size.scale_by(z),
        }
    }

    // Mirrors crates/resvg/src/main.rs `FitTo::fit_to_transform`.
    fn fit_to_transform(&self, size: tiny_skia::IntSize) -> tiny_skia::Transform {
        let size1 = size.to_size();
        let size2 = match self.fit_to_size(size) {
            Some(v) => v.to_size(),
            None => return tiny_skia::Transform::default(),
        };
        tiny_skia::Transform::from_scale(
            size2.width() / size1.width(),
            size2.height() / size1.height(),
        )
    }

    // Mirrors the CLI's `--width/--height` -> `default_size` mapping.
    fn default_size(&self) -> Option<usvg::Size> {
        match *self {
            FitTo::Size(w, h) => usvg::Size::from_wh(w as f32, h as f32),
            FitTo::Width(w) => usvg::Size::from_wh(w as f32, 100.0),
            FitTo::Height(h) => usvg::Size::from_wh(100.0, h as f32),
            FitTo::Original | FitTo::Zoom(_) => None,
        }
    }
}

fn parse_fit_to(width: u32, height: u32, zoom: f32) -> FitTo {
    match (width, height, zoom > 0.0) {
        (0, 0, true) => FitTo::Zoom(zoom),
        (0, 0, false) => FitTo::Original,
        (w, 0, _) => FitTo::Width(w),
        (0, h, _) => FitTo::Height(h),
        (w, h, _) => FitTo::Size(w, h),
    }
}

fn map_shape_rendering(value: i32) -> Option<usvg::ShapeRendering> {
    match value {
        SHAPE_OPTIMIZE_SPEED => Some(usvg::ShapeRendering::OptimizeSpeed),
        SHAPE_CRISP_EDGES => Some(usvg::ShapeRendering::CrispEdges),
        SHAPE_GEOMETRIC_PRECISION => Some(usvg::ShapeRendering::GeometricPrecision),
        _ => None,
    }
}

fn map_text_rendering(value: i32) -> Option<usvg::TextRendering> {
    match value {
        TEXT_OPTIMIZE_SPEED => Some(usvg::TextRendering::OptimizeSpeed),
        TEXT_OPTIMIZE_LEGIBILITY => Some(usvg::TextRendering::OptimizeLegibility),
        TEXT_GEOMETRIC_PRECISION => Some(usvg::TextRendering::GeometricPrecision),
        _ => None,
    }
}

fn map_image_rendering(value: i32) -> Option<usvg::ImageRendering> {
    match value {
        IMAGE_OPTIMIZE_QUALITY => Some(usvg::ImageRendering::OptimizeQuality),
        IMAGE_OPTIMIZE_SPEED => Some(usvg::ImageRendering::OptimizeSpeed),
        IMAGE_SMOOTH => Some(usvg::ImageRendering::Smooth),
        IMAGE_HIGH_QUALITY => Some(usvg::ImageRendering::HighQuality),
        IMAGE_CRISP_EDGES => Some(usvg::ImageRendering::CrispEdges),
        IMAGE_PIXELATED => Some(usvg::ImageRendering::Pixelated),
        _ => None,
    }
}

fn map_indent(value: i32) -> Option<usvg::Indent> {
    match value {
        INDENT_NONE => Some(usvg::Indent::None),
        INDENT_TABS => Some(usvg::Indent::Tabs),
        n if (0..=255).contains(&n) => Some(usvg::Indent::Spaces(n as u8)),
        _ => None,
    }
}

/// Loads image bytes the way upstream's own resolver does, so confined mode
/// accepts exactly the formats default mode accepts. Mirrors
/// `crates/usvg/src/parser/image.rs` (`get_image_file_format` + `load_sub_svg`),
/// which are private to usvg.
fn load_image_bytes(path: &Path, data: Vec<u8>, opts: &usvg::Options) -> Option<usvg::ImageKind> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_lowercase());
    if matches!(ext.as_deref(), Some("svg") | Some("svgz")) {
        return usvg::Tree::from_data_nested(&data, opts)
            .ok()
            .map(usvg::ImageKind::SVG);
    }

    match imagesize::image_type(&data).ok()? {
        imagesize::ImageType::Gif => Some(usvg::ImageKind::GIF(Arc::new(data))),
        imagesize::ImageType::Jpeg => Some(usvg::ImageKind::JPEG(Arc::new(data))),
        imagesize::ImageType::Png => Some(usvg::ImageKind::PNG(Arc::new(data))),
        imagesize::ImageType::Webp => Some(usvg::ImageKind::WEBP(Arc::new(data))),
        _ => None,
    }
}

/// The opt-in confinement resolver: rejects absolute hrefs and any path that
/// resolves outside `resources_dir`. Replacing the default resolver is the
/// upstream-intended extension point (`usvg::Options::image_href_resolver`).
fn confined_string_resolver(root: PathBuf) -> usvg::ImageHrefStringResolverFn<'static> {
    Box::new(move |href: &str, opts: &usvg::Options| {
        let candidate = Path::new(href);
        if candidate.is_absolute() {
            // Rejected: an absolute href ignores resourcesDir entirely.
            return None;
        }
        let resolved = match root.join(candidate).canonicalize() {
            Ok(path) => path,
            Err(_) => return None,
        };
        let canonical_root = match root.canonicalize() {
            Ok(path) => path,
            Err(_) => return None,
        };
        if !resolved.starts_with(&canonical_root) {
            // Rejected: `..` segments or a symlink escaping resourcesDir.
            return None;
        }

        let data = match std::fs::read(&resolved) {
            Ok(data) => data,
            Err(_) => return None,
        };

        load_image_bytes(&resolved, data, opts)
    })
}

/// Builds the reusable options handle. `width`/`height` fix the default size used
/// when an SVG omits absolute dimensions, exactly as the CLI's
/// `--width/--height` do. `font_files` and `font_dirs` are newline-separated.
///
/// # Safety
///
/// Every pointer argument is either null or a valid, NUL-terminated C string that
/// stays alive for the duration of the call.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn resvg_php_options_create(
    resources_dir: *const c_char,
    dpi: f32,
    font_family: *const c_char,
    font_size: f32,
    serif_family: *const c_char,
    sans_serif_family: *const c_char,
    cursive_family: *const c_char,
    fantasy_family: *const c_char,
    monospace_family: *const c_char,
    languages: *const c_char,
    font_files: *const c_char,
    font_dirs: *const c_char,
    load_system_fonts: i32,
    shape_rendering: i32,
    text_rendering: i32,
    image_rendering: i32,
    stylesheet: *const c_char,
    confine_resources: i32,
    width: u32,
    height: u32,
) -> *mut RspOptions {
    clear_last_error();
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Box<RspOptions>, i32> {
        let fit_to = parse_fit_to(width, height, 0.0);

        // A cloned database: `Options::default()` starts with an empty one and
        // the system scan must not repeat per render, so the scan happens here
        // once and every parse shares the `Arc`.
        let mut fontdb = usvg::fontdb::Database::new();
        if load_system_fonts != 0 {
            fontdb.load_system_fonts();
        }
        // Font defaults mirror the CLI's `load_fonts()` exactly (families and
        // precedence), so text output is identical for identical inputs.
        fontdb.set_serif_family(
            cstr_string(serif_family)?.unwrap_or_else(|| "Times New Roman".into()),
        );
        fontdb.set_sans_serif_family(
            cstr_string(sans_serif_family)?.unwrap_or_else(|| "Arial".into()),
        );
        fontdb.set_cursive_family(
            cstr_string(cursive_family)?.unwrap_or_else(|| "Comic Sans MS".into()),
        );
        fontdb.set_fantasy_family(cstr_string(fantasy_family)?.unwrap_or_else(|| "Impact".into()));
        fontdb.set_monospace_family(
            cstr_string(monospace_family)?.unwrap_or_else(|| "Courier New".into()),
        );

        // A failed load is recorded, not logged: `log` has no logger installed
        // in-process, so a `log::warn!` here would be silent. The C layer raises
        // one E_USER_WARNING per failed path from the recorded list, matching
        // upstream's warn-and-continue.
        let mut font_failures: Vec<String> = Vec::new();
        if let Some(list) = cstr_string(font_files)? {
            for path in list.split('\n').map(str::trim).filter(|s| !s.is_empty()) {
                if fontdb.load_font_file(path).is_err() {
                    font_failures.push(path.to_string());
                }
            }
        }
        if let Some(list) = cstr_string(font_dirs)? {
            for dir in list.split('\n').map(str::trim).filter(|s| !s.is_empty()) {
                fontdb.load_fonts_dir(dir);
            }
        }

        let languages = match cstr_string(languages)? {
            Some(list) => list
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect(),
            None => vec!["en".to_string()],
        };

        Ok(Box::new(RspOptions {
            fontdb: Arc::new(fontdb),
            resources_dir: cstr_string(resources_dir)?.map(PathBuf::from),
            confine_resources: confine_resources != 0,
            dpi,
            font_family: cstr_string(font_family)?.unwrap_or_else(|| "Times New Roman".into()),
            font_size,
            languages,
            shape_rendering: map_shape_rendering(shape_rendering)
                .ok_or(RSP_ERROR_INVALID_ARGUMENT)?,
            text_rendering: map_text_rendering(text_rendering).ok_or(RSP_ERROR_INVALID_ARGUMENT)?,
            image_rendering: map_image_rendering(image_rendering)
                .ok_or(RSP_ERROR_INVALID_ARGUMENT)?,
            default_size: fit_to
                .default_size()
                .unwrap_or_else(|| usvg::Size::from_wh(100.0, 100.0).unwrap()),
            style_sheet: cstr_string(stylesheet)?,
            font_failures,
        }))
    }));

    match result {
        Ok(Ok(options)) => Box::into_raw(options),
        Ok(Err(code)) => {
            set_last_error(&describe_status(code));
            std::ptr::null_mut()
        }
        Err(_) => {
            set_last_error("options construction panicked");
            std::ptr::null_mut()
        }
    }
}

/// Parses `data` into a reusable document handle. On failure returns null and
/// writes the status code to `out_status` (when non-null) so the caller can map
/// it onto the PHP exception taxonomy.
///
/// `resources_dir` overrides the handle's own directory for this parse only;
/// null keeps the constructor value. The `*File()` paths pass the file's own
/// directory when the caller set no explicit `resourcesDir`, mirroring the CLI.
///
/// # Safety
///
/// `options` must be a live handle from [`resvg_php_options_create`]; `data` must
/// point to `len` readable bytes; `resources_dir` is null or a valid C string;
/// `out_status` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_tree_parse(
    options: *const RspOptions,
    data: *const u8,
    len: usize,
    resources_dir: *const c_char,
    out_status: *mut i32,
) -> *mut RspTree {
    clear_last_error();
    if !out_status.is_null() {
        unsafe {
            *out_status = RSP_OK;
        }
    }
    if options.is_null() || data.is_null() {
        set_last_error("null pointer passed to parse");
        if !out_status.is_null() {
            unsafe {
                *out_status = RSP_ERROR_NULL_POINTER;
            }
        }
        return std::ptr::null_mut();
    }
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Box<RspTree>, i32> {
        let handle = unsafe { &*options };
        let override_dir = cstr_string(resources_dir)?.map(PathBuf::from);
        let opt = handle.build(override_dir.or_else(|| handle.resources_dir.clone()));
        let bytes = unsafe { slice::from_raw_parts(data, len) };
        let tree = usvg::Tree::from_data(bytes, &opt).map_err(|e| {
            set_last_error(&parse_detail(&e));
            status_of(&e)
        })?;
        Ok(Box::new(RspTree { tree }))
    }));

    match result {
        Ok(Ok(tree)) => Box::into_raw(tree),
        Ok(Err(code)) => {
            if last_error_is_empty() {
                set_last_error(&describe_status(code));
            }
            if !out_status.is_null() {
                unsafe {
                    *out_status = code;
                }
            }
            std::ptr::null_mut()
        }
        Err(_) => {
            set_last_error("parser panicked");
            if !out_status.is_null() {
                unsafe {
                    *out_status = RSP_ERROR_INTERNAL;
                }
            }
            std::ptr::null_mut()
        }
    }
}

/// Human-readable detail for a parse failure, including the parser's own message.
fn parse_detail(error: &usvg::Error) -> String {
    match error {
        usvg::Error::ParsingFailed(e) => format!("parse failed: {e}"),
        other => describe_status(status_of(other)),
    }
}

/// Maps a usvg parse failure onto the ABI status codes.
fn status_of(error: &usvg::Error) -> i32 {
    match error {
        usvg::Error::NotAnUtf8Str => RSP_ERROR_UTF8,
        usvg::Error::InvalidSize => RSP_ERROR_INVALID_SIZE,
        usvg::Error::ElementsLimitReached => RSP_ERROR_ELEMENTS_LIMIT,
        usvg::Error::MalformedGZip => RSP_ERROR_MALFORMED_GZIP,
        usvg::Error::SvgzFeatureNotEnabled => RSP_ERROR_SVGZ_DISABLED,
        usvg::Error::ParsingFailed(_) => RSP_ERROR_PARSING,
    }
}

fn describe_status(code: i32) -> String {
    let text = match code {
        RSP_ERROR_UTF8 => "input is not valid UTF-8",
        RSP_ERROR_INVALID_SIZE => "document has no valid size",
        RSP_ERROR_PARSING => "failed to parse the document",
        RSP_ERROR_ELEMENTS_LIMIT => "element limit reached",
        RSP_ERROR_MALFORMED_GZIP => "malformed gzip stream",
        RSP_ERROR_SVGZ_DISABLED => "svgz support is not compiled in",
        RSP_ERROR_INVALID_ARGUMENT => "invalid option value",
        RSP_ERROR_NO_SUCH_NODE => "no node with the given id",
        RSP_ERROR_ZERO_SIZE_NODE => "node has a zero-size bounding box",
        RSP_ERROR_TOO_LARGE => "render size exceeds resvg.max_render_pixels",
        RSP_ERROR_ALLOCATION => "allocation failed",
        RSP_ERROR_ENCODE => "encoding failed",
        _ => "internal failure",
    };
    text.to_string()
}

fn last_error_is_empty() -> bool {
    LAST_ERROR.with(|slot| slot.borrow().as_bytes().is_empty())
}

/// Runs `body` panic-contained with the §4.3 error lifecycle: the detail is
/// cleared on entry, a mapped failure carries `describe_status` when the body
/// set nothing more specific, and a panic is reported as `RSP_ERROR_INTERNAL`.
/// Every exported function routes through this, so no path can leave a stale
/// message behind or let an unwind cross the boundary.
fn contained<T>(body: impl FnOnce() -> Result<T, i32>) -> Result<T, i32> {
    clear_last_error();
    let result = catch_unwind(AssertUnwindSafe(body)).unwrap_or_else(|_| {
        set_last_error("the operation panicked and was contained");
        Err(RSP_ERROR_INTERNAL)
    });
    if let Err(code) = &result {
        if last_error_is_empty() {
            set_last_error(&describe_status(*code));
        }
    }
    result
}

/// Destroys a tree handle. Null is accepted and ignored.
///
/// # Safety
///
/// `tree` must be a handle from [`resvg_php_tree_parse`] that has not already
/// been freed; it is invalid after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_tree_free(tree: *mut RspTree) {
    if tree.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(tree));
    }
}

/// Reports the document's intrinsic size in user units.
///
/// # Safety
///
/// `tree` must be live; `w` and `h` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_tree_size(
    tree: *const RspTree,
    w: *mut f32,
    h: *mut f32,
) -> i32 {
    match contained(|| {
        if tree.is_null() || w.is_null() || h.is_null() {
            return Err(RSP_ERROR_NULL_POINTER);
        }
        let handle = unsafe { &*tree };
        let size = handle.tree.size();
        unsafe {
            *w = size.width();
            *h = size.height();
        }
        Ok(())
    }) {
        Ok(()) => RSP_OK,
        Err(code) => code,
    }
}

/// Reports the absolute bounding box of the drawing. Returns `RSP_ERROR_ZERO_SIZE_NODE`
/// when the document draws nothing (an empty bbox), which callers surface as null.
///
/// # Safety
///
/// `tree` must be live; the four out pointers must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_tree_bbox(
    tree: *const RspTree,
    x: *mut f32,
    y: *mut f32,
    w: *mut f32,
    h: *mut f32,
) -> i32 {
    match contained(|| {
        if tree.is_null() || x.is_null() || y.is_null() || w.is_null() || h.is_null() {
            return Err(RSP_ERROR_NULL_POINTER);
        }
        let handle = unsafe { &*tree };
        let bbox = handle.tree.root().abs_bounding_box();
        if bbox.width() <= 0.0 || bbox.height() <= 0.0 {
            return Err(RSP_ERROR_ZERO_SIZE_NODE);
        }
        unsafe {
            *x = bbox.x();
            *y = bbox.y();
            *w = bbox.width();
            *h = bbox.height();
        }
        Ok(())
    }) {
        Ok(()) => RSP_OK,
        Err(code) => code,
    }
}

/// True when the document contains a node with this id.
///
/// # Safety
///
/// `tree` must be live; `id` must be a valid NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_tree_node_exists(
    tree: *const RspTree,
    id: *const c_char,
) -> bool {
    contained(|| {
        if tree.is_null() || id.is_null() {
            return Err(RSP_ERROR_NULL_POINTER);
        }
        let handle = unsafe { &*tree };
        let Ok(id) = unsafe { std::ffi::CStr::from_ptr(id) }.to_str() else {
            return Err(RSP_ERROR_UTF8);
        };
        Ok(handle.tree.node_by_id(id).is_some())
    })
    .unwrap_or(false)
}

/// Returns every id in the document, newline-joined, in document order.
///
/// # Safety
///
/// `tree` must be live; `out` and `out_len` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_tree_node_ids(
    tree: *const RspTree,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    match contained(|| {
        if tree.is_null() || out.is_null() || out_len.is_null() {
            return Err(RSP_ERROR_NULL_POINTER);
        }
        unsafe {
            *out = std::ptr::null_mut();
            *out_len = 0;
        }
        let handle = unsafe { &*tree };
        let mut ids: Vec<&str> = Vec::new();
        collect_ids(handle.tree.root(), &mut ids);
        // NUL-separated, not newline: usvg does not enforce XML `Name` on the
        // `id` attribute, so an id may legally contain a newline and a
        // newline-joined wire format could not be split back unambiguously.
        Ok(ids.join("\0").into_bytes())
    }) {
        Ok(bytes) => emit_bytes(bytes, out, out_len),
        Err(code) => code,
    }
}

fn collect_ids<'a>(group: &'a usvg::Group, ids: &mut Vec<&'a str>) {
    if !group.id().is_empty() {
        ids.push(group.id());
    }
    for node in group.children() {
        match node {
            usvg::Node::Group(g) => collect_ids(g, ids),
            usvg::Node::Path(p) => {
                if !p.id().is_empty() {
                    ids.push(p.id());
                }
            }
            usvg::Node::Image(i) => {
                if !i.id().is_empty() {
                    ids.push(i.id());
                }
            }
            usvg::Node::Text(t) => {
                if !t.id().is_empty() {
                    ids.push(t.id());
                }
            }
        }
    }
}

/// Serializes the document back to SVG via upstream's writer.
///
/// # Safety
///
/// `tree` must be live; `id_prefix` is null or a valid C string; `out`/`out_len`
/// must be writable. The returned buffer is released with [`resvg_php_free`].
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn resvg_php_tree_to_svg(
    tree: *const RspTree,
    preserve_text: i32,
    id_prefix: *const c_char,
    indent: i32,
    attrs_indent: i32,
    coordinates_precision: u8,
    transforms_precision: u8,
    use_single_quote: i32,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    match contained(|| -> Result<Vec<u8>, i32> {
        if tree.is_null() || out.is_null() || out_len.is_null() {
            return Err(RSP_ERROR_NULL_POINTER);
        }
        unsafe {
            *out = std::ptr::null_mut();
            *out_len = 0;
        }
        let handle = unsafe { &*tree };
        let Some(indent) = map_indent(indent) else {
            return Err(RSP_ERROR_INVALID_ARGUMENT);
        };
        let Some(attrs_indent) = map_indent(attrs_indent) else {
            return Err(RSP_ERROR_INVALID_ARGUMENT);
        };
        if !(2..=8).contains(&coordinates_precision) || !(2..=8).contains(&transforms_precision) {
            return Err(RSP_ERROR_INVALID_ARGUMENT);
        }

        let opt = usvg::WriteOptions {
            preserve_text: preserve_text != 0,
            id_prefix: cstr_string(id_prefix)?,
            indent,
            attributes_indent: attrs_indent,
            coordinates_precision,
            transforms_precision,
            use_single_quote: use_single_quote != 0,
        };

        Ok(handle.tree.to_string(&opt).into_bytes())
    }) {
        Ok(bytes) => emit_bytes(bytes, out, out_len),
        Err(code) => code,
    }
}

/// Reports the pixel size a render with these fit options would produce, without
/// rasterizing. Uses the same FitTo path as the render, so the two cannot drift.
///
/// # Safety
///
/// `tree` must be live; `out_width`/`out_height` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_tree_measure(
    tree: *const RspTree,
    width: u32,
    height: u32,
    zoom: f32,
    out_width: *mut u32,
    out_height: *mut u32,
) -> i32 {
    match contained(|| {
        if tree.is_null() || out_width.is_null() || out_height.is_null() {
            return Err(RSP_ERROR_NULL_POINTER);
        }
        let handle = unsafe { &*tree };
        let fit_to = parse_fit_to(width, height, zoom);
        let int_size = handle.tree.size().to_int_size();
        let Some(size) = fit_to.fit_to_size(int_size) else {
            return Err(RSP_ERROR_INVALID_SIZE);
        };
        unsafe {
            *out_width = size.width();
            *out_height = size.height();
        }
        Ok(())
    }) {
        Ok(()) => RSP_OK,
        Err(code) => code,
    }
}

/// Renders the whole document to PNG.
///
/// # Safety
///
/// `tree` must be live; `background` is null or a C string; `out`/`out_len` must be
/// writable. The returned buffer is released with [`resvg_php_free`].
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn resvg_php_tree_render(
    tree: *const RspTree,
    width: u32,
    height: u32,
    zoom: f32,
    export_area: i32,
    background: *const c_char,
    max_pixels: u64,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe {
        render_impl(
            tree,
            None,
            width,
            height,
            zoom,
            export_area,
            background,
            max_pixels,
            out,
            out_len,
        )
    }
}

/// Renders a single node (identified by id) to PNG, mirroring `--export-id`.
///
/// # Safety
///
/// As [`resvg_php_tree_render`], plus `id` must be a valid C string.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn resvg_php_tree_render_node(
    tree: *const RspTree,
    id: *const c_char,
    width: u32,
    height: u32,
    zoom: f32,
    export_area: i32,
    background: *const c_char,
    max_pixels: u64,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe {
        render_impl(
            tree,
            Some(id),
            width,
            height,
            zoom,
            export_area,
            background,
            max_pixels,
            out,
            out_len,
        )
    }
}

#[allow(clippy::too_many_arguments)]
unsafe fn render_impl(
    tree: *const RspTree,
    node_id: Option<*const c_char>,
    width: u32,
    height: u32,
    zoom: f32,
    export_area: i32,
    background: *const c_char,
    max_pixels: u64,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    match contained(|| -> Result<Vec<u8>, i32> {
        if tree.is_null() || out.is_null() || out_len.is_null() {
            return Err(RSP_ERROR_NULL_POINTER);
        }
        unsafe {
            *out = std::ptr::null_mut();
            *out_len = 0;
        }
        let handle = unsafe { &*tree };
        let area = match export_area {
            0 => ExportArea::Drawing,
            1 => ExportArea::Page,
            _ => return Err(RSP_ERROR_INVALID_ARGUMENT),
        };
        let background = parse_background(background)?;
        let fit_to = parse_fit_to(width, height, zoom);

        match node_id {
            // Whole-document export: the tree's own size is the fit basis, as in
            // crates/resvg/src/main.rs `render_svg()`'s else branch.
            None => {
                let basis = handle.tree.size().to_int_size();
                let size = fit_to.fit_to_size(basis).ok_or(RSP_ERROR_INVALID_SIZE)?;
                check_pixels(size, max_pixels)?;
                let mut pixmap = tiny_skia::Pixmap::new(size.width(), size.height())
                    .ok_or(RSP_ERROR_ALLOCATION)?;
                fill(&mut pixmap, background);
                let ts = fit_to.fit_to_transform(basis);
                resvg::render(&handle.tree, ts, &mut pixmap.as_mut());
                pixmap.encode_png().map_err(|_| RSP_ERROR_ENCODE)
            }
            // Node export mirrors crates/resvg/src/main.rs:672-726 (`--export-id`)
            // exactly: the pixmap is sized from the node's layer bounding box, the
            // fit transform is computed against the tree size, the node is painted
            // with `render_node`, and page mode is a second tree-sized pixmap with
            // the node pixmap composited at the bbox offset.
            Some(id) => {
                if id.is_null() {
                    return Err(RSP_ERROR_NULL_POINTER);
                }
                let Ok(id) = unsafe { std::ffi::CStr::from_ptr(id) }.to_str() else {
                    return Err(RSP_ERROR_UTF8);
                };
                let node = handle.tree.node_by_id(id).ok_or(RSP_ERROR_NO_SUCH_NODE)?;
                let bbox = node
                    .abs_layer_bounding_box()
                    .ok_or(RSP_ERROR_ZERO_SIZE_NODE)?;

                let size = fit_to
                    .fit_to_size(bbox.size().to_int_size())
                    .ok_or(RSP_ERROR_INVALID_SIZE)?;
                check_pixels(size, max_pixels)?;
                let mut pixmap = tiny_skia::Pixmap::new(size.width(), size.height())
                    .ok_or(RSP_ERROR_ALLOCATION)?;

                if area != ExportArea::Page {
                    fill(&mut pixmap, background);
                }

                let ts = fit_to.fit_to_transform(handle.tree.size().to_int_size());
                resvg::render_node(node, ts, &mut pixmap.as_mut());

                if area == ExportArea::Page {
                    let page_size = fit_to
                        .fit_to_size(handle.tree.size().to_int_size())
                        .ok_or(RSP_ERROR_INVALID_SIZE)?;
                    check_pixels(page_size, max_pixels)?;
                    let mut page_pixmap =
                        tiny_skia::Pixmap::new(page_size.width(), page_size.height())
                            .ok_or(RSP_ERROR_ALLOCATION)?;
                    fill(&mut page_pixmap, background);
                    page_pixmap.draw_pixmap(
                        bbox.x() as i32,
                        bbox.y() as i32,
                        pixmap.as_ref(),
                        &tiny_skia::PixmapPaint::default(),
                        tiny_skia::Transform::default(),
                        None,
                    );
                    page_pixmap.encode_png().map_err(|_| RSP_ERROR_ENCODE)
                } else {
                    pixmap.encode_png().map_err(|_| RSP_ERROR_ENCODE)
                }
            }
        }
    }) {
        Ok(png) => emit_bytes(png, out, out_len),
        Err(code) => code,
    }
}

/// The §7 ceiling is enforced on the produced size, after `fit_to_size` has
/// resolved it — so zoom, single-side fit, default-size and node-export renders
/// are all bounded, and the product is computed in `u64` so it cannot wrap.
fn check_pixels(size: tiny_skia::IntSize, max_pixels: u64) -> Result<(), i32> {
    if max_pixels > 0 && (size.width() as u64) * (size.height() as u64) > max_pixels {
        return Err(RSP_ERROR_TOO_LARGE);
    }
    Ok(())
}

fn fill(pixmap: &mut tiny_skia::Pixmap, background: Option<svgtypes::Color>) {
    if let Some(color) = background {
        pixmap.fill(tiny_skia::Color::from_rgba8(
            color.red,
            color.green,
            color.blue,
            color.alpha,
        ));
    }
}

/// Reports the loaded font faces, newline-joined as `family\tpath\tstatus` rows,
/// followed by one row per font file that failed to load with status `failed`.
///
/// # Safety
///
/// `options` must be live; `out`/`out_len` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_options_fonts(
    options: *const RspOptions,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    match contained(|| {
        if options.is_null() || out.is_null() || out_len.is_null() {
            return Err(RSP_ERROR_NULL_POINTER);
        }
        unsafe {
            *out = std::ptr::null_mut();
            *out_len = 0;
        }
        let handle = unsafe { &*options };
        let mut rows: Vec<String> = Vec::new();
        for face in handle.fontdb.faces() {
            let family = face
                .families
                .first()
                .map(|(name, _)| name.clone())
                .unwrap_or_default();
            let source = match &face.source {
                usvg::fontdb::Source::File(path) => path.display().to_string(),
                usvg::fontdb::Source::Binary(_) => "<binary>".to_string(),
                usvg::fontdb::Source::SharedFile(path, _) => path.display().to_string(),
            };
            rows.push(format!("{family}\t{source}\tok"));
        }
        // A failed path loaded no face, so it appears only here; the C layer
        // raises one E_USER_WARNING per `failed` row.
        for path in &handle.font_failures {
            rows.push(format!("{path}\t{path}\tfailed"));
        }
        rows.sort();
        Ok(rows.join("\n").into_bytes())
    }) {
        Ok(bytes) => emit_bytes(bytes, out, out_len),
        Err(code) => code,
    }
}

/// Destroys an options handle. Null is accepted and ignored.
///
/// # Safety
///
/// `options` must be a handle from [`resvg_php_options_create`] that has not
/// already been freed; it is invalid after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_options_free(options: *mut RspOptions) {
    if options.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(options));
    }
}

/// Frees a buffer produced by any shim function. Null is accepted and ignored.
///
/// # Safety
///
/// `ptr`/`len` must be exactly a pair returned by this shim, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    }
}

/// Borrowed thread-local detail for the last failure. Empty string when the last
/// call succeeded.
#[unsafe(no_mangle)]
pub extern "C" fn resvg_php_last_error() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ptr())
}

#[unsafe(no_mangle)]
pub extern "C" fn resvg_php_version() -> *const c_char {
    // Composite version: package version from php_resvg.h (injected by build.rs)
    // plus the pinned upstream resvg release. Keep the pin in sync with
    // tools/fetch-resvg.sh when bumping upstream.
    static VERSION: &[u8] = concat!(env!("RSP_PACKAGE_VERSION"), "+resvg.0.48.1\0").as_bytes();
    VERSION.as_ptr() as *const c_char
}

fn parse_background(background: *const c_char) -> Result<Option<svgtypes::Color>, i32> {
    match cstr_string(background)? {
        None => Ok(None),
        Some(text) => text
            .parse::<svgtypes::Color>()
            .map(Some)
            .map_err(|_| RSP_ERROR_INVALID_ARGUMENT),
    }
}

fn emit_bytes(bytes: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let ptr = Box::into_raw(boxed) as *mut u8;
    unsafe {
        *out = ptr;
        *out_len = len;
    }
    clear_last_error();
    RSP_OK
}

fn cstr_string(ptr: *const c_char) -> Result<Option<String>, i32> {
    if ptr.is_null() {
        return Ok(None);
    }
    let text = unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| RSP_ERROR_UTF8)?;
    Ok(Some(text.to_string()))
}

// Silence the unused-import warning when the confinement resolver is compiled out.
#[allow(dead_code)]
fn _assert_void_ptr(_: *const c_void) {}
