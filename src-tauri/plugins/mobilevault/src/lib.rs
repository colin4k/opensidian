// SPDX-License-Identifier: GPL-3.0-or-later
//! iOS vault-root access: the document picker and its security-scoped bookmark.
//!
//! This crate is only built for `target_os = "ios"` (see the app's Cargo.toml
//! target section). It is a thin, dependency-free C-ABI layer: Swift owns every
//! decision iOS makes about folder access, and each call answers ONE JSON
//! string, which the app's `platform::ios` module parses. Keeping the parsing
//! out of here means this crate stays free of serde and version skew.
//!
//! Call `pick_folder()` from a BLOCKING thread (Rust's main thread must stay
//! free: the picker it presents is UIKit work that only the main runloop can
//! do, and this call waits for the user). `restore`, `stop_access`,
//! `is_ubiquitous`, `download` and `open_url` are synchronous and safe anywhere
//! off the main thread.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

extern "C" {
    fn opensidian_mv_pick_folder() -> *mut c_char;
    fn opensidian_mv_restore(bookmark: *const c_char) -> *mut c_char;
    fn opensidian_mv_stop_access() -> *mut c_char;
    fn opensidian_mv_is_ubiquitous(path: *const c_char) -> *mut c_char;
    fn opensidian_mv_download(path: *const c_char) -> *mut c_char;
    fn opensidian_mv_open_url(url: *const c_char) -> *mut c_char;
    fn opensidian_mv_diag(message: *const c_char);
    fn opensidian_mv_free(text: *mut c_char);
}

/// Copy the Swift-owned string into a Rust String and release the C copy.
/// A NULL pointer is a bridge bug, not a user-facing state: report it as an
/// error string so the caller's JSON parser produces the one message shape.
fn take(pointer: *mut c_char) -> String {
    if pointer.is_null() {
        return r#"{"error":"the iOS vault bridge returned NULL"}"#.to_string();
    }
    let text = unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned();
    unsafe { opensidian_mv_free(pointer) };
    text
}

fn with_c(value: &str, f: impl FnOnce(*const c_char) -> *mut c_char) -> String {
    match CString::new(value) {
        Ok(c) => take(f(c.as_ptr())),
        // A NUL in a path/bookmark cannot exist in a Rust &str path, but a
        // hand-built bookmark string could carry one: answer, do not abort.
        Err(_) => r#"{"error":"the value contains a NUL byte"}"#.to_string(),
    }
}

/// Append one line to the SAME diagnostics file the Swift side writes
/// (Documents/opensidian-diagnostics.log). Rust has no console on a device whose
/// Console.app cannot see it, so the only way to place a Rust step — "the
/// bookmark was made, the index is building" — on the same timeline as the
/// picker is to hand it to Swift. Best effort: a NUL or a missing file is
/// dropped, never a panic.
pub fn diag(message: &str) {
    if let Ok(c) = CString::new(message) {
        unsafe { opensidian_mv_diag(c.as_ptr()) };
    }
}

/// Present the folder picker. Blocks the calling (worker) thread until the
/// user picks or cancels. JSON: {path, bookmark, name} or {cancelled:true} / {error}.
pub fn pick_folder() -> String {
    take(unsafe { opensidian_mv_pick_folder() })
}

/// Resolve a saved bookmark and start security-scoped access to its folder.
/// JSON: {path, stale, bookmark, name} or {error}. `bookmark` is empty when the
/// saved one is not stale (nothing to rewrite).
pub fn restore(bookmark: &str) -> String {
    with_c(bookmark, |p| unsafe { opensidian_mv_restore(p) })
}

/// Release every folder this process holds open (called when switching vaults).
pub fn stop_access() -> String {
    take(unsafe { opensidian_mv_stop_access() })
}

/// Is this path an iCloud item, and is its content local? JSON: {ubiquitous, download}.
/// Not called by the app yet (P4's offline UX); kept because the Swift side is
/// the same file that owns the download call below.
pub fn is_ubiquitous(path: &str) -> String {
    with_c(path, |p| unsafe { opensidian_mv_is_ubiquitous(p) })
}

/// Ask iCloud to materialise the item behind `path`.
pub fn download(path: &str) -> String {
    with_c(path, |p| unsafe { opensidian_mv_download(p) })
}

/// Open an http/https/mailto URL in the system browser or mail app. The
/// allowlist is enforced on both sides (app::check_external and the Swift
/// function): this call cannot reach any other scheme.
pub fn open_url(url: &str) -> String {
    with_c(url, |p| unsafe { opensidian_mv_open_url(p) })
}
