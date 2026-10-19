// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

//! A small C ABI around Anki's Rust backend, used by the iOS app.
//!
//! There are two ways to talk to it, which share one
//! [anki::backend::Backend] (and so one open collection):
//!
//! - [anki_bridge_rpc] calls any backend service method with protobuf
//!   bytes, exactly like pylib/rsbridge and the desktop's `/_anki/` web
//!   endpoints do.
//! - [anki_bridge_command] takes a JSON command (see [commands::Command]) and
//!   returns a JSON reply of the form `{"ok": <value>}` or `{"error": {"kind":
//!   "...", "message": "..."}}`, for the screens written before the RPC
//!   existed (studying, adding, syncing).

mod commands;
mod render;

use std::ffi::c_char;
use std::ffi::CStr;
use std::ffi::CString;
use std::panic::catch_unwind;
use std::panic::AssertUnwindSafe;

use anki_proto::backend::backend_error::Kind as ErrorKind;
use anki_proto::backend::BackendError;
pub use commands::Bridge;
use prost::Message;
use serde_json::json;

/// Bytes returned by [anki_bridge_rpc], to be released with
/// [anki_bridge_free_buffer]. `data` is null when `len` is 0.
#[repr(C)]
#[derive(Debug)]
pub struct AnkiBuffer {
    pub data: *mut u8,
    pub len: usize,
    /// If true, `data` holds an encoded `anki.backend.BackendError` instead
    /// of the method's response.
    pub is_error: bool,
}

impl AnkiBuffer {
    fn new(bytes: Vec<u8>, is_error: bool) -> Self {
        if bytes.is_empty() {
            return AnkiBuffer {
                data: std::ptr::null_mut(),
                len: 0,
                is_error,
            };
        }
        let len = bytes.len();
        let data = Box::into_raw(bytes.into_boxed_slice()) as *mut u8;
        AnkiBuffer {
            data,
            len,
            is_error,
        }
    }
}

/// Create a new bridge. `langs` is a comma-separated list of preferred
/// languages (eg "pt-BR,en"), and may be null.
///
/// # Safety
/// `langs` must be null or a valid nul-terminated string.
#[no_mangle]
pub unsafe extern "C" fn anki_bridge_new(langs: *const c_char) -> *mut Bridge {
    let langs = if langs.is_null() {
        String::new()
    } else {
        CStr::from_ptr(langs).to_string_lossy().into_owned()
    };
    let langs: Vec<String> = langs
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    Box::into_raw(Box::new(Bridge::new(&langs)))
}

/// Free a bridge created with [anki_bridge_new]. The collection should be
/// closed first.
///
/// # Safety
/// `bridge` must have been returned by [anki_bridge_new] and not freed.
#[no_mangle]
pub unsafe extern "C" fn anki_bridge_free(bridge: *mut Bridge) {
    if !bridge.is_null() {
        // a panic must not unwind across the FFI boundary
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(bridge))));
    }
}

/// Run a JSON command, returning a JSON reply that must be released with
/// [anki_bridge_free_string]. Safe to call from multiple threads, though
/// commands that touch the collection are serialized internally.
///
/// # Safety
/// `bridge` must be valid, and `input` a valid nul-terminated string.
#[no_mangle]
pub unsafe extern "C" fn anki_bridge_command(
    bridge: *const Bridge,
    input: *const c_char,
) -> *mut c_char {
    let bridge = &*bridge;
    let input = CStr::from_ptr(input).to_string_lossy();
    let output = catch_unwind(AssertUnwindSafe(|| bridge.run_json(&input))).unwrap_or_else(|_| {
        json!({"error": {"kind": "PANIC", "message": "unexpected error in Anki core"}}).to_string()
    });
    // JSON output never contains interior nul bytes, as they're escaped
    CString::new(output).unwrap().into_raw()
}

/// Call a backend service method, as pylib/rsbridge's `Backend.command()`
/// does. `service` and `method` are the indices used by the generated
/// Python/TypeScript code; `input` is the encoded request message, and may be
/// null if `input_len` is 0. On success the returned buffer holds the encoded
/// response; if `is_error` is set, it holds an encoded `BackendError`. Safe to
/// call from multiple threads; calls that use the collection are serialized
/// with each other and with [anki_bridge_command].
///
/// # Safety
/// `bridge` must be valid, and `input` must point to `input_len` readable
/// bytes (or be null with `input_len` 0).
#[no_mangle]
pub unsafe extern "C" fn anki_bridge_rpc(
    bridge: *const Bridge,
    service: u32,
    method: u32,
    input: *const u8,
    input_len: usize,
) -> AnkiBuffer {
    let bridge = &*bridge;
    let input = if input.is_null() || input_len == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(input, input_len)
    };
    match catch_unwind(AssertUnwindSafe(|| bridge.rpc(service, method, input))) {
        Ok(Ok(bytes)) => AnkiBuffer::new(bytes, false),
        Ok(Err(bytes)) => AnkiBuffer::new(bytes, true),
        Err(_) => AnkiBuffer::new(panic_error(), true),
    }
}

/// An encoded BackendError for a panic caught at the FFI boundary.
fn panic_error() -> Vec<u8> {
    BackendError {
        message: "unexpected error in Anki core".into(),
        kind: ErrorKind::InvalidInput as i32,
        context: "panic".into(),
        ..Default::default()
    }
    .encode_to_vec()
}

/// Free a buffer returned by [anki_bridge_rpc].
///
/// # Safety
/// `buffer` must have been returned by [anki_bridge_rpc] and not freed.
#[no_mangle]
pub unsafe extern "C" fn anki_bridge_free_buffer(buffer: AnkiBuffer) {
    if !buffer.data.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            buffer.data,
            buffer.len,
        )));
    }
}

/// Ask a running sync/login to stop. Can be called from any thread.
///
/// # Safety
/// `bridge` must be valid.
#[no_mangle]
pub unsafe extern "C" fn anki_bridge_abort_sync(bridge: *const Bridge) {
    let bridge = &*bridge;
    let _ = catch_unwind(AssertUnwindSafe(|| bridge.abort_sync()));
}

/// Free a string returned by [anki_bridge_command].
///
/// # Safety
/// `s` must have been returned by [anki_bridge_command] and not freed.
#[no_mangle]
pub unsafe extern "C" fn anki_bridge_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
