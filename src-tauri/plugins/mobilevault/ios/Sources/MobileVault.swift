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
    /// the window the picker lives in while it is up (see presentPicker); held
    /// strongly here because UIKit does not retain a window for us
    private var presenterWindow: UIWindow?

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

    // MARK: diagnostics

    /// Append one line to Documents/opensidian-diagnostics.log, which the Files
    /// app can read (UIFileSharingEnabled). This exists because a device whose
    /// Console is not reachable still has to report WHICH step of a picker
    /// presentation happened: presenting, picked, cancelled, or nothing at all.
    static func diag(_ message: String) {
        NSLog("[opensidian] %@", message)
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = dir.appendingPathComponent("opensidian-diagnostics.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber,
           size.intValue > 512 * 1024 {
            try? FileManager.default.removeItem(at: file)   // keep it small enough to attach
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// While the caller waits on the picker, ask the main thread every two
    /// seconds whether it is still turning. A picker that "hangs" is either the
    /// system's own UI still enumerating a provider (main thread answers, screen
    /// does not change) or our process wedged somewhere (no answer). Those need
    /// opposite fixes, and on a device whose Console is unreachable the log is
    /// the only place to tell them apart.
    private func watchMainThread(_ box: ResultBox) {
        DispatchQueue.global(qos: .utility).async {
            var ticks = 0
            while !box.answered && ticks < 900 {   // matches the 30-minute wait
                let mark = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { mark.signal() }
                if mark.wait(timeout: .now() + 2) == .timedOut {
                    VaultBridge.diag("main thread did not turn for 2s while the picker was up")
                }
                ticks += 1
                usleep(2_000_000)
            }
        }
    }

    // MARK: pick

    func pickFolder() -> String {
        VaultBridge.diag("pickFolder enter main=\(Thread.isMainThread)")
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
            self.presenting = true
            self.presentPicker(box)
        }
        watchMainThread(box)
        /* Half an hour, not five minutes: the user may leave the sheet open while
           Files copies a large folder (the copy itself can outlast a short
           deadline, and a timeout here only makes the app give up on a picker
           that is still working). The deadline exists to stop a LOST callback
           from wedging every later attempt, not to bound the user. */
        let answer = box.wait(seconds: 1800)
        VaultBridge.diag("pickFolder return \(answer.prefix(60))")
        if answer.contains("did not answer in time") {
            expired()
        }
        return answer
    }

    /// Present the picker in a window of this app's OWN.
    ///
    /// The sheet has two reported failures that look alike from the outside: a
    /// blank sheet while the system's Files process starts (nothing to fix here),
    /// and a sheet that draws, navigates, cancels — but whose Open button never
    /// calls the delegate for ANY folder, iCloud or local, armed (blue) or not.
    /// The second one is about the presentation, not the provider: this app's
    /// window is a WKWebView inside tao's view controller, adopted by a scene
    /// after launch, and a picker hosted on that hierarchy is the long-standing
    /// case where the action is dropped. A fresh, empty window gives the sheet a
    /// host with nothing else in it.
    private func presentPicker(_ box: ResultBox) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let live = scenes.filter { $0.activationState == .foregroundActive }
        guard let scene = (live.isEmpty ? scenes : live).first else {
            box.deliver(mvError("no window scene to present the folder picker"))
            return
        }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root
        window.makeKeyAndVisible()
        presenterWindow = window

        let states = scenes.map { "\($0.activationState.rawValue):\($0.windows.count)" }.joined(separator: ",")
        VaultBridge.diag("present window=\(NSCoder.string(for: window.bounds)) scene=\(scene.activationState.rawValue) scenes=[\(states)] app=\(UIApplication.shared.applicationState.rawValue)")

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        // pageSheet, and not formSheet: on iPhone 26/27 a form sheet is a centred
        // CARD, which clips the location list away (the user then sees only
        // "On My iPhone" and cannot reach iCloud Drive). Asking for fullScreen
        // changes nothing: the picker service renders itself as a sheet.
        picker.modalPresentationStyle = .pageSheet
        picker.shouldShowFileExtensions = true
        /* A CONCRETE starting directory, not the picker's own "Recents": a picker
           that opens on a root where nothing is selectable shows a live-looking
           button and a dead tap. Our own Documents is the one directory this app
           is guaranteed to be able to select, and it is a real location in Files
           ("On My iPhone ▸ Opensidian"). Nothing outside the sandbox: pointing
           directoryURL at an iCloud path we cannot read made iOS wait on it
           instead of falling back, and the picker froze. */
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let start = picker.directoryURL?.path ?? "-"
        VaultBridge.diag("picker start=\(start) exists=\(FileManager.default.fileExists(atPath: start))")

        self.pending = { json in box.deliver(json) }
        root.present(picker, animated: true) {
            VaultBridge.diag("presented")
            /* The sheet's CONTENT belongs to another process, so its view tree is
               the only in-process evidence of what the user is looking at: write it
               down as it settles, before content can exist and then every five
               seconds while the sheet is still up. */
            let t0 = Date()
            var polls = 0
            func dump() {
                let subs = picker.view.subviews
                    .map { "\(type(of: $0)):\(NSCoder.string(for: $0.frame))" }
                    .joined(separator: " ")
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(t0))
                let size = NSCoder.string(for: picker.view.bounds)
                VaultBridge.diag("picker +\(elapsed)s view=\(size) inWindow=\(picker.view.window != nil) subs=[\(subs)]")
            }
            func poll() {
                if box.answered || polls > 12 { return }
                dump()
                polls += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + (polls == 1 ? 1.5 : 5)) { poll() }
            }
            poll()
        }
    }

    /// Give the key back and let the sheet finish dismissing first: hiding the
    /// window underneath a sheet mid-animation is what a flicker (or a stranded
    /// sheet) looks like.
    private func closePresenterWindow() {
        guard let window = presenterWindow else { return }
        presenterWindow = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.isHidden = true
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let others = scenes.flatMap { $0.windows }.filter { $0 !== window && $0.rootViewController != nil }
            others.first(where: { $0.windowLevel == .normal && !$0.isHidden })?.makeKey()
        }
    }

    /// a picker that never called back must not lock every later attempt behind
    /// "already open": clear the in-flight state when the wait expires
    private func expired() {
        DispatchQueue.main.async {
            self.pending = nil
            self.presenting = false
        }
    }

    private func finish(_ json: String) {
        let cb = pending
        pending = nil
        presenting = false
        closePresenterWindow()
        cb?(json)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        VaultBridge.diag("picked \(urls.first?.path ?? "-")")
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
        VaultBridge.diag("cancelled")
        finish("{\"cancelled\":true}")
    }

    // MARK: the app's own iCloud container

    /// The app's OWN folder in iCloud Drive ("iCloud 云盘 ▸ Opensidian").
    ///
    /// This is the one route to a synced vault that does not go through the
    /// document picker: the container belongs to the app, so its URL is a plain
    /// path — no security scope, no bookmark, no handover to be refused.
    /// `url(forUbiquityContainerIdentifier:)` BLOCKS (it starts the ubiquity
    /// machinery), which is why every caller runs off the main thread.
    func iCloudDocuments() -> String {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return mvError("iCloud Drive is not available for this app: sign in to iCloud, enable iCloud Drive, and make sure the build carries the iCloud entitlement")
        }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        } catch {
            return mvError("could not create the iCloud folder: \(error.localizedDescription)")
        }
        VaultBridge.diag("icloud container \(docs.path)")
        return mvJSON(["path": docs.path, "name": "Opensidian"])
    }

    // MARK: adopt

    /// A folder the SYSTEM handed us — Files ▸ Open With, a share sheet target,
    /// or a file provider passing a directory — instead of one the picker
    /// returned. Same contract as a pick: the URL is security-scoped, so the
    /// scope is started here and the bookmark minted before it is handed back,
    /// and the URL is held for as long as it is the vault.
    func adopt(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard url.startAccessingSecurityScopedResource() else {
            return mvError("iOS refused access to that folder")
        }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            hold(url)
            VaultBridge.diag("adopted \(url.path)")
            return mvJSON([
                "path": url.path,
                "bookmark": bookmark.base64EncodedString(),
                "name": url.lastPathComponent,
            ])
        } catch {
            url.stopAccessingSecurityScopedResource()
            return mvError("could not bookmark that folder: \(error.localizedDescription)")
        }
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

}

/// A box the main thread writes and the waiting thread reads after the
/// semaphore. The semaphore is the happens-before edge; the class keeps Swift
/// from capturing a mutable local across two threads.
private final class ResultBox {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: String?
    private var settled = false

    /// Has an answer arrived? Read by the main-thread watcher.
    var answered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    func deliver(_ json: String) {
        lock.lock()
        if value == nil { value = json }
        settled = true
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

@_silgen_name("opensidian_mv_open_url")
public func opensidianMvOpenUrl(_ url: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let url else { return mvDup(mvError("missing url")) }
    let text = String(cString: url)
    // Same allowlist as Rust's check_external: only http/https/mailto leave the
    // app. Kept here too, because this is the function that touches UIApplication.
    guard let target = URL(string: text), let scheme = target.scheme?.lowercased(),
          ["http", "https", "mailto"].contains(scheme) else {
        return mvDup(mvError("refused url: only http, https and mailto leave the app"))
    }
    DispatchQueue.main.async {
        UIApplication.shared.open(target, options: [:], completionHandler: nil)
    }
    return mvDup(mvJSON(["opened": true]))
}

@_silgen_name("opensidian_mv_icloud_documents")
public func opensidianMvICloudDocuments() -> UnsafeMutablePointer<CChar>? {
    mvDup(VaultBridge.shared.iCloudDocuments())
}

@_silgen_name("opensidian_mv_adopt")
public func opensidianMvAdopt(_ path: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let path else { return mvDup(mvError("missing path")) }
    return mvDup(VaultBridge.shared.adopt(String(cString: path)))
}

/// Rust's half of the same log. The app's steps after the picker closes (bind,
/// index, bookmark) run in Rust, and a device that reports "tapping Open does
/// nothing" has to show where that sequence stopped.
@_silgen_name("opensidian_mv_diag")
public func opensidianMvDiag(_ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    VaultBridge.diag(String(cString: message))
}

@_silgen_name("opensidian_mv_free")
public func opensidianMvFree(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}
