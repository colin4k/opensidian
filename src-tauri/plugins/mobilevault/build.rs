// SPDX-License-Identifier: GPL-3.0-or-later
// Build the Swift package only when the TARGET is iOS.
//
// NOT cfg!(target_os = "ios"): a build script is compiled for the HOST (macOS
// here), so its own cfg! always describes the machine doing the build. The
// target is in CARGO_CFG_TARGET_OS. The crate is target-gated in the app's
// Cargo.toml too, so this is a second lock on the same door.
fn main() {
    println!("cargo:rerun-if-changed=ios");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("ios") {
        return;
    }
    // 15.0 matches tauri.conf.json / gen/apple/project.yml (deploymentTarget).
    // Same version in ios/Package.swift — swift-rs links the Swift runtime and
    // the package into this crate's static output.
    swift_rs::SwiftLinker::new("15.0")
        .with_ios("15.0")
        .with_package("OpensidianMobileVault", "ios")
        .link();
}
