// SPDX-License-Identifier: GPL-3.0-or-later
/* THE ONE PLACE THE PLATFORM DIFFERS.

   Everything else in the app is written against this module: where the config
   file lives, what a vault root is allowed to do (desktop: set once, forever;
   iOS: swap it, one process, no second window), how a folder is chosen, and
   whether the OS needs a security-scoped bookmark to keep it reachable.

   Two implementations, chosen at COMPILE time — not a trait object:
     desktop.rs  Linux (and every non-iOS target): the old behaviour, verbatim
     ios.rs      the document picker + bookmark bridge in plugins/mobilevault

   The constants below are what the frontend branches on (platform_info), so the
   UI never guesses from a user agent. */
#[cfg(target_os = "ios")]
mod ios;
#[cfg(target_os = "ios")]
pub use ios::*;

#[cfg(not(target_os = "ios"))]
mod desktop;
#[cfg(not(target_os = "ios"))]
pub use desktop::*;

/// one process, one vault was a desktop invariant (vaultbleed). On iOS there is
/// no second process to spawn, so "open another vault" must swap in place.
pub const IS_MOBILE: bool = cfg!(target_os = "ios");
/// a vault can be replaced inside the running process
pub const CAN_SWITCH_VAULT: bool = cfg!(target_os = "ios");
/// the OS owns folder selection (UIDocumentPicker), not our directory browser
pub const NATIVE_FOLDER_PICKER: bool = cfg!(target_os = "ios");
/// community plugins run code; iOS App Review forbids downloaded code
pub const PLUGINS: bool = !cfg!(target_os = "ios");
/// self-update is an App Store function on iOS
pub const UPDATER: bool = !cfg!(target_os = "ios");

#[derive(Debug, Clone, serde::Serialize)]
pub struct PlatformInfo {
    pub os: &'static str,
    pub mobile: bool,
    pub can_switch_vault: bool,
    pub native_folder_picker: bool,
    pub plugins: bool,
    pub updater: bool,
}

pub fn info() -> PlatformInfo {
    PlatformInfo {
        os: std::env::consts::OS,
        mobile: IS_MOBILE,
        can_switch_vault: CAN_SWITCH_VAULT,
        native_folder_picker: NATIVE_FOLDER_PICKER,
        plugins: PLUGINS,
        updater: UPDATER,
    }
}

/// a folder the user picked, with the bookmark that keeps it reachable
#[derive(Debug, Clone)]
pub struct Picked {
    pub path: String,
    pub bookmark: String,
    pub name: String,
}

/// a bookmark that resolved; `bookmark` is non-empty only when it was stale and
/// the caller must persist the renewed value
#[derive(Debug, Clone)]
pub struct Restored {
    pub path: String,
    pub stale: bool,
    pub bookmark: String,
    pub name: String,
}
