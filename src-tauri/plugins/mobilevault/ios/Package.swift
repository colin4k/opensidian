// swift-tools-version:5.5
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Swift half of the iOS vault bridge. A STATIC product on purpose: swift-rs
// links it into libopensidian_lib.a, which is the only artifact Xcode consumes
// (there is no Swift package reference in gen/apple and none is needed).
//
// No dependencies: this code uses UIKit/Foundation and a plain C ABI, not the
// Tauri Swift runtime, so there is no package to fetch.
import PackageDescription

let package = Package(
    name: "OpensidianMobileVault",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "OpensidianMobileVault",
            type: .static,
            targets: ["OpensidianMobileVault"]
        )
    ],
    targets: [
        .target(
            name: "OpensidianMobileVault",
            path: "Sources"
        )
    ]
)
