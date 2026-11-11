// SPDX-License-Identifier: GPL-3.0-or-later
//
// Vault root access on iOS.
//
// A vault is a FOLDER the user picked once. iOS grants that access as a
// security-scoped bookmark, not as a path: the path alone is refused (EPERM)
// by the sandbox after a cold start. This file owns both halves — present the
// picker, create/resolve the bookmark, and hold startAccessing… open for as
// long as the folder is the vault — and answers Rust with one JSON string per
// call. Every function is a plain C symbol (@_silgen_name), because Rust does
// not run a Tauri plugin here: the bridge is a static library, not a runtime.
//
// THREADING: pickFolder presents UI and therefore needs the main thread, while
// Rust must not block the main thread waiting for it. The caller is a blocking
// thread (spawn_blocking); presentation is dispatched to main and the caller
// waits on a semaphore. Any other call is synchronous and safe from a
// background thread.

import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - JSON helpers

private func mvJSON(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let text = String(data: data, encoding: .utf8) else {
        return "{\"error\":\"bridge could not encode its answer\"}"
    }
    return text
}

private func mvError(_ why: String) -> String {
    mvJSON(["error": why])
}

// MARK: - The bridge

private final class VaultBridge: NSObject, UIDocumentPickerDelegate {
    static let shared = VaultBridge()

    private let lock = NSLock()
    /// folder path -> URL whose security scope is currently open
    private var active: [String: URL] = [:]
    /// at most one picker at a time; set and cleared on the main thread
    private var pending: ((String) -> Void)?
    private var presenting = false

    private func held(_ path: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return active[path]
    }

    private func hold(_ url: URL) {
        lock.lock()
        active[url.path] = url
        lock.unlock()
    }

    // MARK: pick

    func pickFolder() -> String {
        if Thread.isMainThread {
            // Never wait on the runloop we are about to need.
            return mvError("folder picker called on the main thread; call it from a worker thread")
        }
        let box = ResultBox()
        DispatchQueue.main.async {
            guard !self.presenting else {
                box.deliver(mvError("a folder picker is already open"))
                return
            }
            guard let host = VaultBridge.topViewController() else {
                box.deliver(mvError("no view controller to present the folder picker"))
                return
            }
            self.presenting = true
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            picker.modalPresentationStyle = .formSheet
            self.pending = { json in box.deliver(json) }
            host.present(picker, animated: true)
        }
        return box.wait(seconds: 600)
    }

    private func finish(_ json: String) {
        let cb = pending
        pending = nil
        presenting = false
        cb?(json)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            finish(mvError("no folder was picked"))
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            finish(mvError("iOS refused access to that folder"))
            return
        }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            hold(url)
            finish(mvJSON([
                "path": url.path,
                "bookmark": bookmark.base64EncodedString(),
                "name": url.lastPathComponent,
            ]))
        } catch {
            url.stopAccessingSecurityScopedResource()
            finish(mvError("could not bookmark that folder: \(error.localizedDescription)"))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish("{\"cancelled\":true}")
    }

    // MARK: restore

    func restore(_ base64: String) -> String {
        guard let data = Data(base64Encoded: base64) else {
            return mvError("saved bookmark is not valid base64")
        }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                return mvError("the saved folder is no longer accessible; pick it again")
            }
            hold(url)
            // A stale bookmark still resolved; rewrite it so the next launch
            // does not depend on the old inode. Empty = no rewrite needed.
            var fresh = ""
            if stale, let renewed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                fresh = renewed.base64EncodedString()
            }
            return mvJSON([
                "path": url.path,
                "stale": stale,
                "bookmark": fresh,
                "name": url.lastPathComponent,
            ])
        } catch {
            return mvError("the saved folder could not be resolved: \(error.localizedDescription)")
        }
    }

    // MARK: access + iCloud state

    func stopAccess() -> String {
        lock.lock()
        let urls = active.values
        active.removeAll()
        lock.unlock()
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
        return mvJSON(["stopped": urls.count])
    }

    func isUbiquitous(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        var answer = "unknown"
        switch values?.ubiquitousItemDownloadingStatus {
        case .some(.current): answer = "current"
        case .some(.downloaded): answer = "downloaded"
        case .some(.notDownloaded): answer = "notDownloaded"
        default: break
        }
        return mvJSON([
            "ubiquitous": values?.isUbiquitousItem ?? false,
            "download": answer,
        ])
    }

    func download(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            return mvJSON(["started": true])
        } catch {
            return mvError("iCloud download did not start: \(error.localizedDescription)")
        }
    }

    // MARK: presentation

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController {
            top = next
        }
        return top
    }
}

/// A box the main thread writes and the waiting thread reads after the
/// semaphore. The semaphore is the happens-before edge; the class keeps Swift
/// from capturing a mutable local across two threads.
private final class ResultBox {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: String?

    func deliver(_ json: String) {
        lock.lock()
        if value == nil { value = json }
        lock.unlock()
        sem.signal()
    }

    func wait(seconds: Int) -> String {
        if sem.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
            return mvError("the folder picker did not answer in time")
        }
        lock.lock()
        defer { lock.unlock() }
        return value ?? mvError("the folder picker returned nothing")
    }
}

// MARK: - C ABI (the names Rust declares)

private func mvDup(_ text: String) -> UnsafeMutablePointer<CChar>? {
    strdup(text)
}

@_silgen_name("opensidian_mv_pick_folder")
public func opensidianMvPickFolder() -> UnsafeMutablePointer<CChar>? {
    mvDup(VaultBridge.shared.pickFolder())
}

@_silgen_name("opensidian_mv_restore")
public func opensidianMvRestore(_ bookmark: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let bookmark else { return mvDup(mvError("missing bookmark")) }
    return mvDup(VaultBridge.shared.restore(String(cString: bookmark)))
}

@_silgen_name("opensidian_mv_stop_access")
public func opensidianMvStopAccess() -> UnsafeMutablePointer<CChar>? {
    mvDup(VaultBridge.shared.stopAccess())
}

@_silgen_name("opensidian_mv_is_ubiquitous")
public func opensidianMvIsUbiquitous(_ path: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let path else { return mvDup(mvError("missing path")) }
    return mvDup(VaultBridge.shared.isUbiquitous(String(cString: path)))
}

@_silgen_name("opensidian_mv_download")
public func opensidianMvDownload(_ path: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let path else { return mvDup(mvError("missing path")) }
    return mvDup(VaultBridge.shared.download(String(cString: path)))
}

@_silgen_name("opensidian_mv_free")
public func opensidianMvFree(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}
