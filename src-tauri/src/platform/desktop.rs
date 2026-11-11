// SPDX-License-Identifier: GPL-3.0-or-later
/* Desktop (Linux, and any non-iOS build) platform layer.

   NOTHING HERE IS NEW BEHAVIOUR. RootSlot wraps the same OnceLock the Vault
   used directly, config_path is the same ~/.opensidian.json, and the lock dir is
   vaultlock's. The module exists so the app can name the platform seam once. */
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use super::{Picked, Restored};

/// The vault root, claimed ONCE for the life of the process (vaultbleed). The
/// second set is Err, exactly like the OnceLock it wraps: every desktop window
/// is one process on one vault, and reopening goes through a new process.
pub struct RootSlot(OnceLock<PathBuf>);

impl RootSlot {
    pub const fn new() -> Self {
        Self(OnceLock::new())
    }

    pub fn get(&self) -> Option<PathBuf> {
        self.0.get().cloned()
    }

    pub fn set(&self, p: PathBuf) -> Result<(), ()> {
        self.0.set(p).map_err(|_| ())
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

pub fn config_path() -> PathBuf {
    home().join(".opensidian.json")
}

pub fn config_lock_dir() -> PathBuf {
    crate::vaultlock::env_lock_dir()
}

/// iOS parks the config under Library/Application Support, whose parent may not
/// exist yet; the desktop config lives in $HOME, which does.
pub fn prepare_config_dirs() {}

pub fn pick_folder() -> Result<Picked, String> {
    Err("this platform has no native folder picker; the app's own browser is used".into())
}

/// The iOS picker log has no desktop counterpart: stderr is always there.
pub fn diag(_message: &str) {}

/// Desktop opens folders through its own browser; nothing is handed to the app
/// as a security-scoped URL.
pub fn adopt_folder(_path: &Path) -> Result<Picked, String> {
    Err("this platform does not adopt folders from the system".into())
}

pub fn restore_bookmark(_base64: &str) -> Result<Restored, String> {
    Err("security-scoped bookmarks are an iOS feature".into())
}

/// iOS drops the folder's security scope when the vault is replaced.
pub fn release_vault_access() {}

/// iCloud content materialisation; a desktop path is always local.
pub fn download(_path: &Path) -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The desktop invariant vaultbleed rests on: a process never re-roots.
    /// (The iOS RootSlot is the opposite by design and is covered by the
    /// platform split itself — it cannot be run on this target.)
    #[test]
    fn root_slot_is_set_once_on_desktop() {
        let slot = RootSlot::new();
        assert!(slot.get().is_none());
        assert!(slot.set(PathBuf::from("/v/one")).is_ok());
        assert_eq!(slot.get(), Some(PathBuf::from("/v/one")));
        assert!(slot.set(PathBuf::from("/v/two")).is_err(), "desktop must never re-root");
        assert_eq!(slot.get(), Some(PathBuf::from("/v/one")), "the refused set changed nothing");
    }

    #[test]
    fn config_lives_in_home_on_desktop() {
        assert!(config_path().ends_with(".opensidian.json"));
    }
}

/// The only way an external URL leaves the app (check_external has already
/// applied the scheme allowlist). std::process::Command only — no shell, no
/// opener plugin. A missing xdg-open (headless smoke, minimal hosts) is a plain
/// Err, never a fallback.
pub fn open_external(url: &str) -> Result<(), String> {
    std::process::Command::new("xdg-open")
        .arg(url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}
