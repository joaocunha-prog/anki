// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

//! A small C ABI around Anki's Rust backend, used by the iOS app.
//!
//! Swift sends a JSON command (see [commands::Command]) and receives a JSON
//! reply of the form `{"ok": <value>}` or
//! `{"error": {"kind": "...", "message": "..."}}`. JSON keeps the Swift side
//! free of generated protobuf code, while all of the real work (scheduling,
//! rendering, AnkiWeb sync) is still done by the shared Rust core.

mod commands;
mod render;

use std::ffi::c_char;
use std::ffi::CStr;
use std::ffi::CString;
use std::panic::catch_unwind;
use std::panic::AssertUnwindSafe;

pub use commands::Bridge;
use serde_json::json;

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
        drop(Box::from_raw(bridge));
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

/// Ask a running sync/login to stop. Can be called from any thread.
///
/// # Safety
/// `bridge` must be valid.
#[no_mangle]
pub unsafe extern "C" fn anki_bridge_abort_sync(bridge: *const Bridge) {
    (*bridge).abort_sync();
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
