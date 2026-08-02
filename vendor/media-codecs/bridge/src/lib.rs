//! Panic-contained native media decoding for language bindings.
//!
//! This crate deliberately knows nothing about atlases, asset identifiers,
//! manifests, packs, or any engine. It owns only generic image decoding, font
//! rasterization, and audio decoding behind a fixed-width C ABI. Callers own
//! every output buffer; opaque resources are represented by validated integer
//! handles and must be closed through this library.

use std::collections::HashMap;
use std::io::Cursor;
use std::num::NonZeroU32;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use fontdue::{Font, FontSettings};
use image::{ImageReader, Limits as ImageLimits};
use symphonium::{DecodeConfig, decode_f32, probe_from_source};
use thiserror::Error;

/// ABI revision implemented by this dynamic library.
pub const API_VERSION: u32 = 1;

/// The operation completed successfully.
pub const STATUS_OK: u32 = 0;
/// A pointer, size, scalar, or ABI structure was invalid.
pub const STATUS_INVALID_ARGUMENT: u32 = 1;
/// The source uses a valid but unsupported format or channel layout.
pub const STATUS_UNSUPPORTED: u32 = 2;
/// The source could not be parsed or decoded.
pub const STATUS_DECODE_FAILED: u32 = 3;
/// A configured safety limit would be exceeded.
pub const STATUS_LIMIT_EXCEEDED: u32 = 4;
/// A caller-owned destination cannot hold the complete result.
pub const STATUS_BUFFER_TOO_SMALL: u32 = 5;
/// An opaque handle does not identify a live resource.
pub const STATUS_NOT_FOUND: u32 = 6;
/// A dependency panicked; the panic was contained at the ABI boundary.
pub const STATUS_PANICKED: u32 = 7;

/// Caller-provided limits shared by every decoding operation.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct MediaCodecLimits {
    /// Must equal `sizeof(MediaCodecLimits)` in the caller ABI.
    pub struct_size: u32,
    /// Must equal [`API_VERSION`].
    pub api_version: u32,
    /// Maximum encoded source size in bytes.
    pub max_source_bytes: u64,
    /// Maximum decoded output size in bytes.
    pub max_decoded_bytes: u64,
    /// Maximum width or height of an image or glyph.
    pub max_dimension: u32,
    /// Reserved for a future compatible extension; set to zero.
    pub reserved: u32,
}

/// Dimensions and byte requirements for one RGBA8 image.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct MediaImageInfo {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Image width in pixels.
    pub width: u32,
    /// Image height in pixels.
    pub height: u32,
    /// Number of RGBA8 bytes in one tightly packed row.
    pub row_bytes: u32,
    /// Total number of decoded bytes.
    pub byte_len: u64,
}

/// Horizontal font metrics at one requested pixel size.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct MediaFontMetrics {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Distance above the baseline.
    pub ascent: f32,
    /// Distance below the baseline.
    pub descent: f32,
    /// Extra vertical gap between lines.
    pub line_gap: f32,
    /// Recommended baseline-to-baseline distance.
    pub new_line_size: f32,
}

/// Metrics and coverage-buffer requirements for one rasterized glyph.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct MediaGlyphInfo {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Unicode scalar value represented by this glyph.
    pub codepoint: u32,
    /// Coverage bitmap width in pixels.
    pub width: u32,
    /// Coverage bitmap height in pixels.
    pub height: u32,
    /// Horizontal bitmap offset from the glyph origin.
    pub xmin: i32,
    /// Vertical bitmap offset from the glyph origin.
    pub ymin: i32,
    /// Horizontal advance after drawing the glyph.
    pub advance_width: f32,
    /// Vertical advance after drawing the glyph.
    pub advance_height: f32,
    /// Number of one-byte alpha coverage values.
    pub bitmap_bytes: u64,
}

/// Description of one decoded, interleaved stereo audio resource.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct MediaAudioInfo {
    /// Size of this structure in bytes.
    pub struct_size: u32,
    /// Output sample rate in hertz.
    pub sample_rate: u32,
    /// Output channel count. This ABI currently always produces two channels.
    pub channels: u32,
    /// Reserved for a future compatible extension; currently zero.
    pub reserved: u32,
    /// Number of stereo frames.
    pub frames: u64,
    /// Number of interleaved `f32` samples.
    pub sample_count: u64,
}

#[derive(Debug, Error)]
enum CodecError {
    #[error("invalid codec argument")]
    InvalidArgument,
    #[error("unsupported media representation")]
    Unsupported,
    #[error("media decoding failed")]
    DecodeFailed,
    #[error("media safety limit exceeded")]
    LimitExceeded,
    #[error("destination buffer is too small")]
    BufferTooSmall,
    #[error("opaque media handle is not live")]
    NotFound,
}

impl CodecError {
    const fn status(&self) -> u32 {
        match self {
            Self::InvalidArgument => STATUS_INVALID_ARGUMENT,
            Self::Unsupported => STATUS_UNSUPPORTED,
            Self::DecodeFailed => STATUS_DECODE_FAILED,
            Self::LimitExceeded => STATUS_LIMIT_EXCEEDED,
            Self::BufferTooSmall => STATUS_BUFFER_TOO_SMALL,
            Self::NotFound => STATUS_NOT_FOUND,
        }
    }
}

struct RasterizedGlyph {
    info: MediaGlyphInfo,
    coverage: Vec<u8>,
}

struct DecodedAudio {
    info: MediaAudioInfo,
    samples: Vec<f32>,
}

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
static FONTS: OnceLock<Mutex<HashMap<u64, Arc<Font>>>> = OnceLock::new();
static GLYPHS: OnceLock<Mutex<HashMap<u64, Arc<RasterizedGlyph>>>> = OnceLock::new();
static AUDIO: OnceLock<Mutex<HashMap<u64, Arc<DecodedAudio>>>> = OnceLock::new();

fn font_store() -> &'static Mutex<HashMap<u64, Arc<Font>>> {
    FONTS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn glyph_store() -> &'static Mutex<HashMap<u64, Arc<RasterizedGlyph>>> {
    GLYPHS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn audio_store() -> &'static Mutex<HashMap<u64, Arc<DecodedAudio>>> {
    AUDIO.get_or_init(|| Mutex::new(HashMap::new()))
}

fn store_handle<T>(store: &Mutex<HashMap<u64, Arc<T>>>, value: T) -> Result<u64, CodecError> {
    let mut values = store
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    values
        .try_reserve(1)
        .map_err(|_| CodecError::LimitExceeded)?;
    loop {
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        if handle != 0 && !values.contains_key(&handle) {
            values.insert(handle, Arc::new(value));
            return Ok(handle);
        }
    }
}

fn load_handle<T>(store: &Mutex<HashMap<u64, Arc<T>>>, handle: u64) -> Result<Arc<T>, CodecError> {
    if handle == 0 {
        return Err(CodecError::NotFound);
    }
    store
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(&handle)
        .cloned()
        .ok_or(CodecError::NotFound)
}

fn close_handle<T>(store: &Mutex<HashMap<u64, Arc<T>>>, handle: u64) -> Result<(), CodecError> {
    if handle == 0 {
        return Err(CodecError::NotFound);
    }
    store
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .remove(&handle)
        .map_or(Err(CodecError::NotFound), |_| Ok(()))
}

fn ffi_status(action: impl FnOnce() -> Result<(), CodecError>) -> u32 {
    match catch_unwind(AssertUnwindSafe(action)) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(error)) => error.status(),
        Err(_) => STATUS_PANICKED,
    }
}

fn structure_size<T>() -> Result<u32, CodecError> {
    u32::try_from(std::mem::size_of::<T>()).map_err(|_| CodecError::InvalidArgument)
}

unsafe fn read_limits(pointer: *const MediaCodecLimits) -> Result<MediaCodecLimits, CodecError> {
    if pointer.is_null() {
        return Err(CodecError::InvalidArgument);
    }
    // SAFETY: The caller contract guarantees one aligned, initialized limits structure.
    let limits = unsafe { pointer.read() };
    if limits.struct_size != structure_size::<MediaCodecLimits>()?
        || limits.api_version != API_VERSION
        || limits.max_source_bytes == 0
        || limits.max_decoded_bytes == 0
        || limits.max_dimension == 0
        || limits.reserved != 0
    {
        return Err(CodecError::InvalidArgument);
    }
    Ok(limits)
}

unsafe fn source_bytes<'source>(
    pointer: *const u8,
    length: usize,
    limits: MediaCodecLimits,
) -> Result<&'source [u8], CodecError> {
    if length == 0 || pointer.is_null() {
        return Err(CodecError::InvalidArgument);
    }
    let encoded_bytes = u64::try_from(length).map_err(|_| CodecError::LimitExceeded)?;
    if encoded_bytes > limits.max_source_bytes {
        return Err(CodecError::LimitExceeded);
    }
    // SAFETY: The caller contract guarantees `length` readable bytes at `pointer`.
    Ok(unsafe { std::slice::from_raw_parts(pointer, length) })
}

unsafe fn write_value<T: Copy>(destination: *mut T, value: T) -> Result<(), CodecError> {
    if destination.is_null() || !(destination as usize).is_multiple_of(std::mem::align_of::<T>()) {
        return Err(CodecError::InvalidArgument);
    }
    // SAFETY: The caller provides one aligned writable `T` that does not alias input data.
    unsafe { destination.write(value) };
    Ok(())
}

unsafe fn copy_output<T: Copy>(
    destination: *mut T,
    capacity: usize,
    source: &[T],
) -> Result<(), CodecError> {
    if source.len() > capacity {
        return Err(CodecError::BufferTooSmall);
    }
    if source.is_empty() {
        return Ok(());
    }
    if destination.is_null() || !(destination as usize).is_multiple_of(std::mem::align_of::<T>()) {
        return Err(CodecError::InvalidArgument);
    }
    // SAFETY: The caller provides `capacity >= source.len()` writable elements,
    // and caller-owned output cannot overlap library-owned resource storage.
    unsafe { std::ptr::copy_nonoverlapping(source.as_ptr(), destination, source.len()) };
    Ok(())
}

fn owned_source(source: &[u8]) -> Result<Vec<u8>, CodecError> {
    let mut owned = Vec::new();
    owned
        .try_reserve_exact(source.len())
        .map_err(|_| CodecError::LimitExceeded)?;
    owned.extend_from_slice(source);
    Ok(owned)
}

fn checked_image_info(
    width: u32,
    height: u32,
    limits: MediaCodecLimits,
) -> Result<MediaImageInfo, CodecError> {
    if width == 0 || height == 0 || width > limits.max_dimension || height > limits.max_dimension {
        return Err(CodecError::LimitExceeded);
    }
    let row_bytes = width.checked_mul(4).ok_or(CodecError::LimitExceeded)?;
    let byte_len = u64::from(row_bytes)
        .checked_mul(u64::from(height))
        .ok_or(CodecError::LimitExceeded)?;
    if byte_len > limits.max_decoded_bytes {
        return Err(CodecError::LimitExceeded);
    }
    Ok(MediaImageInfo {
        struct_size: structure_size::<MediaImageInfo>()?,
        width,
        height,
        row_bytes,
        byte_len,
    })
}

fn image_reader(
    source: &[u8],
    limits: MediaCodecLimits,
) -> Result<ImageReader<Cursor<&[u8]>>, CodecError> {
    let mut reader = ImageReader::new(Cursor::new(source))
        .with_guessed_format()
        .map_err(|_| CodecError::DecodeFailed)?;
    let mut image_limits = ImageLimits::default();
    image_limits.max_image_width = Some(limits.max_dimension);
    image_limits.max_image_height = Some(limits.max_dimension);
    image_limits.max_alloc = Some(limits.max_decoded_bytes);
    reader.limits(image_limits);
    Ok(reader)
}

fn probe_image(source: &[u8], limits: MediaCodecLimits) -> Result<MediaImageInfo, CodecError> {
    let (width, height) = image_reader(source, limits)?
        .into_dimensions()
        .map_err(|_| CodecError::DecodeFailed)?;
    checked_image_info(width, height, limits)
}

fn decode_image(source: &[u8], limits: MediaCodecLimits) -> Result<Vec<u8>, CodecError> {
    let image = image_reader(source, limits)?
        .decode()
        .map_err(|_| CodecError::DecodeFailed)?
        .into_rgba8();
    let info = checked_image_info(image.width(), image.height(), limits)?;
    let pixels = image.into_raw();
    if u64::try_from(pixels.len()) != Ok(info.byte_len) {
        return Err(CodecError::DecodeFailed);
    }
    Ok(pixels)
}

/// Returns the fixed ABI revision implemented by the loaded library.
#[must_use]
#[unsafe(no_mangle)]
pub const extern "C" fn media_codec_api_version() -> u32 {
    API_VERSION
}

/// Probes one encoded image without retaining an opaque resource.
///
/// # Safety
///
/// `source` must expose `source_len` readable bytes. `limits` and `output`
/// must each point to one aligned, live structure for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn media_codec_image_probe(
    source: *const u8,
    source_len: usize,
    limits: *const MediaCodecLimits,
    output: *mut MediaImageInfo,
) -> u32 {
    ffi_status(|| {
        // SAFETY: The public ABI contract covers every pointer used below.
        let limits = unsafe { read_limits(limits)? };
        // SAFETY: The public ABI contract covers the bounded source buffer.
        let source = unsafe { source_bytes(source, source_len, limits)? };
        let info = probe_image(source, limits)?;
        // SAFETY: The public ABI contract covers one writable output structure.
        unsafe { write_value(output, info) }
    })
}

/// Decodes one encoded image into caller-owned tightly packed RGBA8 storage.
///
/// Call [`media_codec_image_probe`] first to determine the exact required byte
/// length. No partial result is copied when `destination_capacity` is too small.
///
/// # Safety
///
/// `source` must expose `source_len` readable bytes. `limits` must point to one
/// live structure. `destination` must expose `destination_capacity` writable
/// bytes and must not overlap the source.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn media_codec_image_decode_rgba8(
    source: *const u8,
    source_len: usize,
    limits: *const MediaCodecLimits,
    destination: *mut u8,
    destination_capacity: usize,
) -> u32 {
    ffi_status(|| {
        // SAFETY: The public ABI contract covers every pointer used below.
        let limits = unsafe { read_limits(limits)? };
        // SAFETY: The public ABI contract covers the bounded source buffer.
        let source = unsafe { source_bytes(source, source_len, limits)? };
        let pixels = decode_image(source, limits)?;
        // SAFETY: The public ABI contract covers the caller-owned destination.
        unsafe { copy_output(destination, destination_capacity, &pixels) }
    })
}

/// Parses one font and returns a live opaque handle.
///
/// # Safety
///
/// `source` must expose `source_len` readable bytes. `limits` and `handle`
/// must point to aligned live values. The returned handle must eventually be
/// passed to [`media_codec_font_close`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn media_codec_font_open(
    source: *const u8,
    source_len: usize,
    limits: *const MediaCodecLimits,
    handle: *mut u64,
) -> u32 {
    ffi_status(|| {
        if handle.is_null() {
            return Err(CodecError::InvalidArgument);
        }
        // SAFETY: The public ABI contract covers every pointer used below.
        let limits = unsafe { read_limits(limits)? };
        // SAFETY: The public ABI contract covers the bounded source buffer.
        let source = unsafe { source_bytes(source, source_len, limits)? };
        let font = Font::from_bytes(owned_source(source)?, FontSettings::default())
            .map_err(|_| CodecError::DecodeFailed)?;
        let stored = store_handle(font_store(), font)?;
        // SAFETY: The public ABI contract covers one writable handle.
        unsafe { write_value(handle, stored) }
    })
}

/// Reads horizontal line metrics from a live font handle.
///
/// # Safety
///
/// `output` must point to one aligned writable structure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn media_codec_font_metrics(
    handle: u64,
    pixel_size: f32,
    output: *mut MediaFontMetrics,
) -> u32 {
    ffi_status(|| {
        if !pixel_size.is_finite() || pixel_size <= 0.0 {
            return Err(CodecError::InvalidArgument);
        }
        let font = load_handle(font_store(), handle)?;
        let metrics = font.horizontal_line_metrics(pixel_size).map_or(
            MediaFontMetrics {
                struct_size: 0,
                ascent: pixel_size,
                descent: 0.0,
                line_gap: 0.0,
                new_line_size: pixel_size,
            },
            |metrics| MediaFontMetrics {
                struct_size: 0,
                ascent: metrics.ascent,
                descent: metrics.descent,
                line_gap: metrics.line_gap,
                new_line_size: metrics.new_line_size,
            },
        );
        let metrics = MediaFontMetrics {
            struct_size: structure_size::<MediaFontMetrics>()?,
            ..metrics
        };
        // SAFETY: The public ABI contract covers one writable output structure.
        unsafe { write_value(output, metrics) }
    })
}

/// Rasterizes one Unicode scalar into an owned alpha-coverage resource.
///
/// The returned glyph handle can be read concurrently and remains independent
/// of the font handle. Close it with [`media_codec_glyph_close`].
///
/// # Safety
///
/// `limits`, `glyph_handle`, and `output` must each point to aligned live
/// structures or values for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn media_codec_font_rasterize(
    font_handle: u64,
    codepoint: u32,
    pixel_size: f32,
    limits: *const MediaCodecLimits,
    glyph_handle: *mut u64,
    output: *mut MediaGlyphInfo,
) -> u32 {
    ffi_status(|| {
        if glyph_handle.is_null()
            || output.is_null()
            || !pixel_size.is_finite()
            || pixel_size <= 0.0
        {
            return Err(CodecError::InvalidArgument);
        }
        let character = char::from_u32(codepoint).ok_or(CodecError::InvalidArgument)?;
        // SAFETY: The public ABI contract covers the limits structure.
        let limits = unsafe { read_limits(limits)? };
        let font = load_handle(font_store(), font_handle)?;
        let (metrics, coverage) = font.rasterize(character, pixel_size);
        let width = u32::try_from(metrics.width).map_err(|_| CodecError::LimitExceeded)?;
        let height = u32::try_from(metrics.height).map_err(|_| CodecError::LimitExceeded)?;
        if width > limits.max_dimension || height > limits.max_dimension {
            return Err(CodecError::LimitExceeded);
        }
        let bitmap_bytes = u64::try_from(coverage.len()).map_err(|_| CodecError::LimitExceeded)?;
        if bitmap_bytes > limits.max_decoded_bytes {
            return Err(CodecError::LimitExceeded);
        }
        let info = MediaGlyphInfo {
            struct_size: structure_size::<MediaGlyphInfo>()?,
            codepoint,
            width,
            height,
            xmin: metrics.xmin,
            ymin: metrics.ymin,
            advance_width: metrics.advance_width,
            advance_height: metrics.advance_height,
            bitmap_bytes,
        };
        let stored = store_handle(glyph_store(), RasterizedGlyph { info, coverage })?;
        // SAFETY: The public ABI contract covers both writable outputs.
        unsafe {
            write_value(glyph_handle, stored)?;
            write_value(output, info)
        }
    })
}

/// Copies one complete alpha-coverage bitmap into caller-owned bytes.
///
/// # Safety
///
/// `destination` must expose `destination_capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn media_codec_glyph_copy(
    handle: u64,
    destination: *mut u8,
    destination_capacity: usize,
) -> u32 {
    ffi_status(|| {
        let glyph = load_handle(glyph_store(), handle)?;
        // SAFETY: The public ABI contract covers the caller-owned destination.
        unsafe { copy_output(destination, destination_capacity, &glyph.coverage) }
    })
}

/// Re-reads immutable metadata for one live glyph handle.
///
/// # Safety
///
/// `output` must point to one aligned writable structure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn media_codec_glyph_info(handle: u64, output: *mut MediaGlyphInfo) -> u32 {
    ffi_status(|| {
        let glyph = load_handle(glyph_store(), handle)?;
        // SAFETY: The public ABI contract covers one writable output structure.
        unsafe { write_value(output, glyph.info) }
    })
}

/// Releases one font handle.
#[unsafe(no_mangle)]
pub extern "C" fn media_codec_font_close(handle: u64) -> u32 {
    ffi_status(|| close_handle(font_store(), handle))
}

/// Releases one rasterized glyph handle.
#[unsafe(no_mangle)]
pub extern "C" fn media_codec_glyph_close(handle: u64) -> u32 {
    ffi_status(|| close_handle(glyph_store(), handle))
}

fn decode_audio_source(
    source: &[u8],
    target_sample_rate: u32,
    limits: MediaCodecLimits,
) -> Result<DecodedAudio, CodecError> {
    let target_sample_rate = NonZeroU32::new(target_sample_rate)
        .filter(|rate| (8_000..=192_000).contains(&rate.get()))
        .ok_or(CodecError::InvalidArgument)?;
    let source = Cursor::new(owned_source(source)?);
    let probed =
        probe_from_source(Box::new(source), None, None).map_err(|_| CodecError::DecodeFailed)?;
    if probed.num_channels().get() > 2 {
        return Err(CodecError::Unsupported);
    }
    let max_bytes =
        usize::try_from(limits.max_decoded_bytes).map_err(|_| CodecError::LimitExceeded)?;
    let config = DecodeConfig {
        max_bytes,
        verify: true,
        cache_decoder: false,
        cache_resampler: false,
        ..DecodeConfig::default()
    };
    let decoded = decode_f32(probed, &config, Some(target_sample_rate), None, None)
        .map_err(|_| CodecError::DecodeFailed)?;
    let frames = decoded.frames();
    if frames == 0 {
        return Err(CodecError::DecodeFailed);
    }
    let sample_count = frames.checked_mul(2).ok_or(CodecError::LimitExceeded)?;
    let byte_len = sample_count
        .checked_mul(4)
        .ok_or(CodecError::LimitExceeded)?;
    let decoded_bytes = u64::try_from(byte_len).map_err(|_| CodecError::LimitExceeded)?;
    if decoded_bytes > limits.max_decoded_bytes {
        return Err(CodecError::LimitExceeded);
    }
    let left = decoded.data.first().ok_or(CodecError::DecodeFailed)?;
    let right = if decoded.channels() == 1 {
        left
    } else {
        decoded.data.get(1).ok_or(CodecError::DecodeFailed)?
    };
    if left.len() != frames || right.len() != frames {
        return Err(CodecError::DecodeFailed);
    }
    let mut samples = Vec::new();
    samples
        .try_reserve_exact(sample_count)
        .map_err(|_| CodecError::LimitExceeded)?;
    for frame in 0..frames {
        let left_sample = *left.get(frame).ok_or(CodecError::DecodeFailed)?;
        let right_sample = *right.get(frame).ok_or(CodecError::DecodeFailed)?;
        if !left_sample.is_finite() || !right_sample.is_finite() {
            return Err(CodecError::DecodeFailed);
        }
        samples.push(left_sample);
        samples.push(right_sample);
    }
    let frames = u64::try_from(frames).map_err(|_| CodecError::LimitExceeded)?;
    let sample_count = u64::try_from(sample_count).map_err(|_| CodecError::LimitExceeded)?;
    Ok(DecodedAudio {
        info: MediaAudioInfo {
            struct_size: structure_size::<MediaAudioInfo>()?,
            sample_rate: target_sample_rate.get(),
            channels: 2,
            reserved: 0,
            frames,
            sample_count,
        },
        samples,
    })
}

/// Decodes and resamples one source into an owned interleaved stereo resource.
///
/// Close the returned handle with [`media_codec_audio_close`].
///
/// # Safety
///
/// `source` must expose `source_len` readable bytes. `limits`, `audio_handle`,
/// and `output` must each point to aligned live values or structures.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn media_codec_audio_decode(
    source: *const u8,
    source_len: usize,
    target_sample_rate: u32,
    limits: *const MediaCodecLimits,
    audio_handle: *mut u64,
    output: *mut MediaAudioInfo,
) -> u32 {
    ffi_status(|| {
        if audio_handle.is_null() || output.is_null() {
            return Err(CodecError::InvalidArgument);
        }
        // SAFETY: The public ABI contract covers every pointer used below.
        let limits = unsafe { read_limits(limits)? };
        // SAFETY: The public ABI contract covers the bounded source buffer.
        let source = unsafe { source_bytes(source, source_len, limits)? };
        let audio = decode_audio_source(source, target_sample_rate, limits)?;
        let info = audio.info;
        let stored = store_handle(audio_store(), audio)?;
        // SAFETY: The public ABI contract covers both writable outputs.
        unsafe {
            write_value(audio_handle, stored)?;
            write_value(output, info)
        }
    })
}

/// Copies all interleaved stereo samples into caller-owned `f32` storage.
///
/// # Safety
///
/// `destination` must expose `destination_capacity` aligned writable `f32`
/// elements and cannot alias library-owned storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn media_codec_audio_copy(
    handle: u64,
    destination: *mut f32,
    destination_capacity: usize,
) -> u32 {
    ffi_status(|| {
        let audio = load_handle(audio_store(), handle)?;
        // SAFETY: The public ABI contract covers the caller-owned destination.
        unsafe { copy_output(destination, destination_capacity, &audio.samples) }
    })
}

/// Re-reads immutable metadata for one live audio handle.
///
/// # Safety
///
/// `output` must point to one aligned writable structure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn media_codec_audio_info(handle: u64, output: *mut MediaAudioInfo) -> u32 {
    ffi_status(|| {
        let audio = load_handle(audio_store(), handle)?;
        // SAFETY: The public ABI contract covers one writable output structure.
        unsafe { write_value(output, audio.info) }
    })
}

/// Releases one decoded audio handle.
#[unsafe(no_mangle)]
pub extern "C" fn media_codec_audio_close(handle: u64) -> u32 {
    ffi_status(|| close_handle(audio_store(), handle))
}

#[cfg(test)]
mod tests {
    use image::codecs::png::PngEncoder;
    use image::{ExtendedColorType, ImageEncoder};

    use super::*;

    fn limits() -> MediaCodecLimits {
        MediaCodecLimits {
            struct_size: u32::try_from(std::mem::size_of::<MediaCodecLimits>())
                .expect("limits structure size should fit u32"),
            api_version: API_VERSION,
            max_source_bytes: 1_048_576,
            max_decoded_bytes: 1_048_576,
            max_dimension: 1_024,
            reserved: 0,
        }
    }

    fn one_pixel_png() -> Vec<u8> {
        let mut encoded = Vec::new();
        PngEncoder::new(&mut encoded)
            .write_image(&[1, 2, 3, 4], 1, 1, ExtendedColorType::Rgba8)
            .expect("PNG fixture should encode");
        encoded
    }

    fn two_frame_wav() -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&40_u32.to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&8_000_u32.to_le_bytes());
        bytes.extend_from_slice(&16_000_u32.to_le_bytes());
        bytes.extend_from_slice(&2_u16.to_le_bytes());
        bytes.extend_from_slice(&16_u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&4_u32.to_le_bytes());
        bytes.extend_from_slice(&0_i16.to_le_bytes());
        bytes.extend_from_slice(&i16::MAX.to_le_bytes());
        bytes
    }

    #[test]
    fn image_decode_should_report_exact_rgba8_layout() {
        let source = one_pixel_png();
        let limits = limits();
        let mut info = MediaImageInfo::default();
        // SAFETY: Every pointer refers to a live bounded test fixture.
        let probe_status = unsafe {
            media_codec_image_probe(
                source.as_ptr(),
                source.len(),
                &raw const limits,
                &raw mut info,
            )
        };
        let mut pixels = vec![0_u8; 4];
        // SAFETY: Every pointer refers to a live bounded test fixture.
        let decode_status = unsafe {
            media_codec_image_decode_rgba8(
                source.as_ptr(),
                source.len(),
                &raw const limits,
                pixels.as_mut_ptr(),
                pixels.len(),
            )
        };

        assert_eq!(
            (probe_status, decode_status, info.width, info.height, pixels),
            (STATUS_OK, STATUS_OK, 1, 1, vec![1, 2, 3, 4])
        );
    }

    #[test]
    fn audio_decode_should_convert_mono_to_interleaved_stereo() {
        let source = two_frame_wav();
        let limits = limits();
        let mut handle = 0_u64;
        let mut info = MediaAudioInfo::default();
        // SAFETY: Every pointer refers to a live bounded test fixture.
        let decode_status = unsafe {
            media_codec_audio_decode(
                source.as_ptr(),
                source.len(),
                8_000,
                &raw const limits,
                &raw mut handle,
                &raw mut info,
            )
        };
        let mut samples = vec![0.0_f32; 4];
        // SAFETY: `samples` exposes the exact writable sample count.
        let copy_status =
            unsafe { media_codec_audio_copy(handle, samples.as_mut_ptr(), samples.len()) };
        let close_status = media_codec_audio_close(handle);

        assert_eq!(
            (
                decode_status,
                copy_status,
                close_status,
                info.channels,
                info.frames
            ),
            (STATUS_OK, STATUS_OK, STATUS_OK, 2, 2)
        );
        assert!((samples[0] - samples[1]).abs() <= f32::EPSILON);
        assert!((samples[2] - samples[3]).abs() <= f32::EPSILON);
    }

    #[test]
    fn closed_handles_should_be_rejected_without_dereferencing_memory() {
        let source = two_frame_wav();
        let limits = limits();
        let mut handle = 0_u64;
        let mut info = MediaAudioInfo::default();
        // SAFETY: Every pointer refers to a live bounded test fixture.
        let opened = unsafe {
            media_codec_audio_decode(
                source.as_ptr(),
                source.len(),
                8_000,
                &raw const limits,
                &raw mut handle,
                &raw mut info,
            )
        };
        let closed = media_codec_audio_close(handle);
        let mut samples = [0.0_f32; 4];
        // SAFETY: `samples` is live; the closed handle must fail before copying.
        let copied = unsafe { media_codec_audio_copy(handle, samples.as_mut_ptr(), samples.len()) };

        assert_eq!(
            (opened, closed, copied),
            (STATUS_OK, STATUS_OK, STATUS_NOT_FOUND)
        );
    }
}
