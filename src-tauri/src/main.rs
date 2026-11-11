// SPDX-License-Identifier: GPL-3.0-or-later
// opensidian, a vault-compatible markdown notes app.
// Copyright (C) 2026 Jendrik Poloczek
// This program comes with ABSOLUTELY NO WARRANTY. It is free software, and you
// are welcome to redistribute it under the terms of the GNU GPL version 3 or
// (at your option) any later version. See LICENSE, or <https://www.gnu.org/licenses/>.
/* THE DESKTOP BINARY, and nothing else.

   Every line of the app — argv boot, vault binding, the landlock opt-in, the
   Tauri builder, all 130 commands — is in `opensidian_lib::app::run`
   (src/app.rs). It moved there for iOS: Tauri mobile links the LIBRARY
   (libopensidian_lib.a) and never compiles a bin target, so the entry point
   has to be reachable from the lib. Keeping this file empty of logic means the
   desktop and the phone run the same code, not a copy. */
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    opensidian_lib::run()
}
