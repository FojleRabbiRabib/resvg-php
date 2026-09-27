// resvg-php Rust shim: the resvg crate behind a flat C ABI.
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
// FitTo semantics mirror crates/resvg/src/main.rs verbatim: that function pair is
// the definition of CLI-compatible sizing.

use std::ffi::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;

pub const RSP_OK: i32 = 0;
pub const RSP_ERROR_NULL_POINTER: i32 = 1;
pub const RSP_ERROR_UTF8: i32 = 2;
pub const RSP_ERROR_INVALID_SIZE: i32 = 3;
pub const RSP_ERROR_PARSING: i32 = 4;
pub const RSP_ERROR_ALLOCATION: i32 = 5;
pub const RSP_ERROR_ENCODE: i32 = 6;
pub const RSP_ERROR_INTERNAL: i32 = 7;
pub const RSP_ERROR_INVALID_ARGUMENT: i32 = 8;

/// A reusable parse/render configuration: font database, DPI, language list, stylesheet,
/// and the default sizing applied when a render specifies no explicit size.
pub struct RspOptions {
    opt: usvg::Options<'static>,
    fit_to: FitTo,
}

#[derive(Clone, Copy)]
enum FitTo {
    Original,
    Width(u32),
    Height(u32),
    Size(u32, u32),
    Zoom(f32),
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

/// Builds the reusable options handle. `width`/`height` fix the default size used when
/// an SVG omits absolute dimensions, exactly as the CLI's `--width/--height` do.
/// `font_files` is a newline-separated list of font paths.
///
/// # Safety
///
/// Every pointer argument is either null or a valid, NUL-terminated C string that
/// stays alive for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_options_create(
    resources_dir: *const c_char,
    dpi: f32,
    font_family: *const c_char,
    font_size: f32,
    languages: *const c_char,
    font_files: *const c_char,
    stylesheet: *const c_char,
    width: u32,
    height: u32,
) -> *mut RspOptions {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Box<RspOptions>, i32> {
        let fit_to = parse_fit_to(width, height, 0.0);
        let mut opt = usvg::Options::<'static> {
            resources_dir: cstr_string(resources_dir)?.map(Into::into),
            dpi: if dpi > 0.0 { dpi } else { 96.0 },
            font_size: if font_size > 0.0 { font_size } else { 12.0 },
            default_size: fit_to
                .default_size()
                .unwrap_or_else(|| usvg::Size::from_wh(100.0, 100.0).unwrap()),
            ..Default::default()
        };

        if let Some(family) = cstr_string(font_family)? {
            opt.font_family = family;
        }
        if let Some(list) = cstr_string(languages)? {
            opt.languages = list
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
        opt.style_sheet = cstr_string(stylesheet)?;

        // Font defaults mirror the CLI's `load_fonts()` exactly (families and
        // precedence), so text output is identical for identical inputs.
        let fontdb = opt.fontdb_mut();
        fontdb.load_system_fonts();
        fontdb.set_serif_family("Times New Roman");
        fontdb.set_sans_serif_family("Arial");
        fontdb.set_cursive_family("Comic Sans MS");
        fontdb.set_fantasy_family("Impact");
        fontdb.set_monospace_family("Courier New");
        if let Some(list) = cstr_string(font_files)? {
            for path in list.split('\n').map(str::trim).filter(|s| !s.is_empty()) {
                if let Err(e) = fontdb.load_font_file(path) {
                    eprintln!("resvg-php: failed to load font '{path}': {e}");
                }
            }
        }

        Ok(Box::new(RspOptions { opt, fit_to }))
    }));

    match result {
        Ok(Ok(options)) => Box::into_raw(options),
        _ => std::ptr::null_mut(),
    }
}

/// Parses `data` and renders it to PNG bytes.
///
/// `width`/`height`/`zoom` override the handle's default sizing; passing all zeros
/// renders at the document's own size, or at the handle's configured size when the
/// document has none.
///
/// # Safety
///
/// `options` must be a handle from [`resvg_php_options_create`] that has not been
/// freed; `data` must point to `len` readable bytes; `out` and `out_len` must be
/// writable. The returned buffer must be released with [`resvg_php_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_render(
    options: *const RspOptions,
    data: *const u8,
    len: usize,
    width: u32,
    height: u32,
    zoom: f32,
    background: *const c_char,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Vec<u8>, i32> {
        if options.is_null() || data.is_null() || out.is_null() || out_len.is_null() {
            return Err(RSP_ERROR_NULL_POINTER);
        }
        unsafe {
            *out = std::ptr::null_mut();
            *out_len = 0;
        }
        let handle = unsafe { &*options };
        let fit_to = if width == 0 && height == 0 && zoom <= 0.0 {
            handle.fit_to
        } else {
            parse_fit_to(width, height, zoom)
        };
        let bytes = unsafe { slice::from_raw_parts(data, len) };
        let tree = usvg::Tree::from_data(bytes, &handle.opt).map_err(|e| match e {
            usvg::Error::NotAnUtf8Str => RSP_ERROR_UTF8,
            usvg::Error::InvalidSize => RSP_ERROR_INVALID_SIZE,
            usvg::Error::ElementsLimitReached
            | usvg::Error::MalformedGZip
            | usvg::Error::SvgzFeatureNotEnabled
            | usvg::Error::ParsingFailed(_) => RSP_ERROR_PARSING,
        })?;
        render_png(&tree, fit_to, parse_background(background)?)
    }));

    match result {
        Ok(Ok(png)) => emit_png(png, out, out_len),
        Ok(Err(code)) => code,
        Err(_) => RSP_ERROR_INTERNAL,
    }
}

/// Reports the rendered pixel size for `data` without encoding a PNG.
///
/// # Safety
///
/// `options` must be a live handle from [`resvg_php_options_create`]; `data` must
/// point to `len` readable bytes; `out_width` and `out_height` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_measure(
    options: *const RspOptions,
    data: *const u8,
    len: usize,
    width: u32,
    height: u32,
    zoom: f32,
    out_width: *mut u32,
    out_height: *mut u32,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<(u32, u32), i32> {
        if options.is_null() || data.is_null() || out_width.is_null() || out_height.is_null() {
            return Err(RSP_ERROR_NULL_POINTER);
        }
        let handle = unsafe { &*options };
        let fit_to = if width == 0 && height == 0 && zoom <= 0.0 {
            handle.fit_to
        } else {
            parse_fit_to(width, height, zoom)
        };
        let bytes = unsafe { slice::from_raw_parts(data, len) };
        let tree = usvg::Tree::from_data(bytes, &handle.opt).map_err(|e| match e {
            usvg::Error::NotAnUtf8Str => RSP_ERROR_UTF8,
            usvg::Error::InvalidSize => RSP_ERROR_INVALID_SIZE,
            usvg::Error::ElementsLimitReached
            | usvg::Error::MalformedGZip
            | usvg::Error::SvgzFeatureNotEnabled
            | usvg::Error::ParsingFailed(_) => RSP_ERROR_PARSING,
        })?;
        let size = fit_to
            .fit_to_size(tree.size().to_int_size())
            .ok_or(RSP_ERROR_INVALID_SIZE)?;
        Ok((size.width(), size.height()))
    }));

    match result {
        Ok(Ok((w, h))) => {
            unsafe {
                *out_width = w;
                *out_height = h;
            }
            RSP_OK
        }
        Ok(Err(code)) => code,
        Err(_) => RSP_ERROR_INTERNAL,
    }
}

/// Destroys an options handle. Null is accepted and ignored.
///
/// # Safety
///
/// `options` must be a handle from [`resvg_php_options_create`] that has not already
/// been freed; it is invalid after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_options_free(options: *mut RspOptions) {
    if options.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(options));
    }
}

/// Frees a PNG buffer produced by [`resvg_php_render`]. Null is accepted and ignored.
///
/// # Safety
///
/// `ptr`/`len` must be exactly the pair returned by [`resvg_php_render`], not yet
/// freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn resvg_php_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn resvg_php_version() -> *const c_char {
    static VERSION: &[u8] = b"0.1.0+resvg.0.48.1\0";
    VERSION.as_ptr() as *const c_char
}

// Mirrors the CLI's `render_svg()` happy path for whole-document exports.
fn render_png(
    tree: &usvg::Tree,
    fit_to: FitTo,
    background: Option<svgtypes::Color>,
) -> Result<Vec<u8>, i32> {
    let int_size = tree.size().to_int_size();
    let size = fit_to.fit_to_size(int_size).ok_or(RSP_ERROR_INVALID_SIZE)?;
    let mut pixmap =
        tiny_skia::Pixmap::new(size.width(), size.height()).ok_or(RSP_ERROR_ALLOCATION)?;
    if let Some(color) = background {
        pixmap.fill(tiny_skia::Color::from_rgba8(
            color.red,
            color.green,
            color.blue,
            color.alpha,
        ));
    }
    resvg::render(
        tree,
        fit_to.fit_to_transform(int_size),
        &mut pixmap.as_mut(),
    );
    pixmap.encode_png().map_err(|_| RSP_ERROR_ENCODE)
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

fn emit_png(png: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    let boxed = png.into_boxed_slice();
    let len = boxed.len();
    let ptr = Box::into_raw(boxed) as *mut u8;
    unsafe {
        *out = ptr;
        *out_len = len;
    }
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
