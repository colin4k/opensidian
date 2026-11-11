// SPDX-License-Identifier: GPL-3.0-or-later
/* iOS platform layer.

   A vault is a FOLDER the user picked in Files or iCloud Drive. The sandbox does
   not hand out paths, it hands out a security-scoped bookmark, and the scope is
   only live while someone holds startAccessingSecurityScopedResource(). The
   Swift half (plugins/mobilevault) owns that; this file parses its answers and
   maps them onto the app's one vault-root concept.

   THREADING: pick_folder blocks until the user answers. Commands call it from
   tauri::async_runtime::spawn_blocking, exactly like secrets_op does — never on
   the main thread, or the picker it presents could never be shown. */
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use super::{Picked, Restored};

/// The vault root, replaceable. One process, no second window (there is no
/// fork/exec on iOS), so "open another vault" is a swap: the old folder's
/// security scope is released by bind_vault before the new path is claimed.
pub struct RootSlot(Mutex<Option<PathBuf>>);

impl RootSlot {
    pub const fn new() -> Self {
        Self(Mutex::new(None))
    }

    pub fn get(&self) -> Option<PathBuf> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn set(&self, p: PathBuf) -> Result<(), ()> {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = Some(p);
        Ok(())
    }
}

impl Default for RootSlot {
    fn default() -> Self {
        Self::new()
    }
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".into()))
}

/// The app container's Library/Application Support, not $HOME: only Documents
/// and Library are part of an iCloud/iTunes backup, so a config in the
/// container root would vanish on restore-from-backup.
fn support_dir() -> PathBuf {
    home().join("Library/Application Support/dev.koto.opensidian")
}

pub fn config_path() -> PathBuf {
    support_dir().join("config.json")
}

pub fn config_lock_dir() -> PathBuf {
    support_dir().join("locks")
}

/// cfgstore writes a temp file next to the config and renames; both parents have
/// to exist before the first write, and the first write happens on the first
/// preference change, not at a convenient moment.
pub fn prepare_config_dirs() {
    for d in [support_dir(), config_lock_dir()] {
        if let Err(e) = std::fs::create_dir_all(&d) {
            eprintln!("[ios] could not create {}: {e}", d.display());
        }
    }
}

/// The bridge answers one JSON string per call: either the fields below or
/// {"error": "..."} / {"cancelled": true}. One parser, so every failure reaches
/// the UI as a sentence instead of a silent empty vault.
fn answer(text: String) -> Result<serde_json::Value, String> {
    let v: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| format!("vault bridge answered non-JSON ({e}): {text}"))?;
    if v["cancelled"].as_bool() == Some(true) {
        return Err("cancelled".into());
    }
    if let Some(why) = v["error"].as_str() {
        return Err(why.to_string());
    }
    Ok(v)
}

pub fn pick_folder() -> Result<Picked, String> {
    let v = answer(opensidian_mobilevault::pick_folder())?;
    Ok(Picked {
        path: v["path"].as_str().ok_or("vault bridge: no path in the answer")?.to_string(),
        bookmark: v["bookmark"].as_str().unwrap_or_default().to_string(),
        name: v["name"].as_str().unwrap_or_default().to_string(),
    })
}

/// One line into the picker's diagnostics log (Documents/opensidian-diagnostics.log).
/// The Swift half owns the file: Rust has no console on a device that Console.app
/// cannot see, and the steps AFTER the picker closes run here.
pub fn diag(message: &str) {
    opensidian_mobilevault::diag(message);
}

/// A folder the system opened the app with, rather than one the picker returned.
/// The URL is security-scoped the same way, so the bridge starts it and mints the
/// bookmark; the answer has the same shape as a pick.
pub fn adopt_folder(path: &Path) -> Result<Picked, String> {
    let v = answer(opensidian_mobilevault::adopt(&path.display().to_string()))?;
    Ok(Picked {
        path: v["path"].as_str().ok_or("vault bridge: no path in the answer")?.to_string(),
        bookmark: v["bookmark"].as_str().unwrap_or_default().to_string(),
        name: v["name"].as_str().unwrap_or_default().to_string(),
    })
}

pub fn restore_bookmark(base64: &str) -> Result<Restored, String> {
    let v = answer(opensidian_mobilevault::restore(base64))?;
    Ok(Restored {
        path: v["path"].as_str().ok_or("vault bridge: no path in the answer")?.to_string(),
        stale: v["stale"].as_bool().unwrap_or(false),
        bookmark: v["bookmark"].as_str().unwrap_or_default().to_string(),
        name: v["name"].as_str().unwrap_or_default().to_string(),
    })
}

/// Drop every folder scope this process holds. Called when the vault is
/// replaced; a failure is logged, never fatal — the URL objects still go away
/// with the process.
pub fn release_vault_access() {
    if let Err(e) = answer(opensidian_mobilevault::stop_access()) {
        eprintln!("[ios] could not release the old folder: {e}");
    }
}

/// Ask iCloud to materialise the item behind `path`. A local file is a no-op the
/// bridge reports as an error; the caller treats that as "already here".
pub fn download(path: &Path) -> Result<(), String> {
    let v = answer(opensidian_mobilevault::download(&path.display().to_string()))?;
    if v["started"].as_bool() == Some(true) {
        Ok(())
    } else {
        Err("iCloud did not start a download".into())
    }
}

/// The only way an external URL leaves the app. check_external has already
/// applied the scheme allowlist; the bridge applies it again because it is the
/// code that touches UIApplication.
pub fn open_external(url: &str) -> Result<(), String> {
    let v = answer(opensidian_mobilevault::open_url(url))?;
    if v["opened"].as_bool() == Some(true) {
        Ok(())
    } else {
        Err("the system did not open that link".into())
    }
}
