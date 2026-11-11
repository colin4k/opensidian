// SPDX-License-Identifier: GPL-3.0-or-later
// opensidian, a vault-compatible markdown notes app.
// Copyright (C) 2026 Jendrik Poloczek
/* opensidian_lib — the WHOLE application as a library.

   WHY: Tauri mobile (iOS/Android) links a static library, never a binary — the
   Xcode project embeds libopensidian_lib.a and calls the
   `#[tauri::mobile_entry_point]` `run()` inside it. So the app layer
   (src/app.rs) lives here behind the default `app` feature and src/main.rs is
   a one-line caller. On desktop nothing changed but the compilation unit: the
   same code, the same `crate::` paths, the same tests.

   The PURE parse/normalize modules (vaultfs, outline, index, graphq, canvasfs,
   datefmt) are deliberately NOT gated: fuzz/ links this crate with
   default-features = false and must keep compiling them without the tauri
   runtime, a webview or GTK. Add a module to the ungated block ONLY if it is
   tauri-free and a fuzz target needs it. */
/* lost-write: a dropped Result is how a failed save becomes a reported
   success. rustc warned about exactly that in link_mention for weeks and
   nobody read the build log — a warning nobody reads is not a safety net.
   DENY, so the next one is a build error. Where ignoring is genuinely right,
   write `let _ = ...` WITH a reason next to it. */
#![deny(unused_must_use)]

/* P0/ios: on non-Linux targets some Linux-only surfaces (landlock roots, the
   Secret Service, the plugin-store transport, process spawning) are compiled
   but unreachable — the mobile command list does not expose them yet. Until P2
   removes them outright, silence exactly that dead-code noise so a REAL
   warning on the mobile build is still visible. Linux, the shipping target,
   keeps every lint. */
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

pub mod canvasfs;
pub mod datefmt;
pub mod graphq;
pub mod index;
pub mod outline;
pub mod vaultfs;

// ---- the app layer (feature = "app", default on) ----
#[cfg(feature = "app")]
mod appid;
#[cfg(feature = "app")]
mod builtins;
#[cfg(feature = "app")]
mod cfgstore;
#[cfg(feature = "app")]
mod census;
// spawn-consent: native GTK prompts before trusting a vault and before every plugin spawn
#[cfg(feature = "app")]
mod consent;
#[cfg(feature = "app")]
mod desk_http;
#[cfg(feature = "app")]
mod desk_net;
#[cfg(feature = "app")]
mod desk_proc;
#[cfg(feature = "app")]
#[cfg(feature = "devui")]
mod devui; // goal devui: DEV-ONLY UI hot reload, never in a default/release build
#[cfg(feature = "app")]
mod migrate;
#[cfg(feature = "app")]
mod pasteimg;
#[cfg(feature = "app")]
mod pdf;
#[cfg(feature = "app")]
mod perf;
#[cfg(feature = "app")]
mod platform;
#[cfg(feature = "app")]
mod plugin_store;
#[cfg(feature = "app")]
mod plugins;
#[cfg(feature = "app")]
mod qscreate;
#[cfg(feature = "app")]
mod sandbox;
// cp-secrets: app.secretStorage over the OS keyring (Secret Service)
#[cfg(feature = "app")]
mod secrets;
#[cfg(feature = "app")]
mod settings;
#[cfg(feature = "app")]
mod spawn;
#[cfg(feature = "app")]
mod spawner;
#[cfg(feature = "app")]
mod srcmode;
#[cfg(test)]
mod testutil;
#[cfg(feature = "app")]
mod themefs;
#[cfg(feature = "app")]
mod updates;
#[cfg(feature = "app")]
mod vaultlock;
#[cfg(feature = "app")]
mod watcher;
#[cfg(feature = "app")]
mod winsize;

// The app itself, LAST: `perf` and `plugin_store` define `#[macro_export]`
// macros that app.rs uses by bare name (`span_timed!`, `compat_app_version!`),
// and a macro_rules! is only in textual scope for items declared AFTER the
// module that defines it.
#[cfg(feature = "app")]
mod app;

// The entry point the bin and the mobile runtime call.
#[cfg(feature = "app")]
pub use app::run;
// Root-level names the app's own submodules reach for (`crate::Vault`,
// `crate::cur_vault`, `crate::cfg_value`, `crate::render_md`,
// `crate::MAX_IMG_BYTES`, and pasteimg's four path helpers). They live in
// `mod app` now, so re-export them here: moving the file must not move every
// call site's path.
#[cfg(feature = "app")]
pub(crate) use app::{
    cand_names, cfg_value, cur_vault, note_path_in, note_rel, render_md, safe_rel, Vault,
    MAX_IMG_BYTES,
};
