import Foundation
import WebKit

/// Path B from the Chrome extension's playbook: download video bytes via
/// URLSession to a local tmp file, then hand WebVideoPlayer a `file://`
/// URL. This eliminates the network roundtrip when the visible WebView
/// mounts its `<video>` element — playback starts essentially as fast as
/// the disk read + decoder init (~50-100ms instead of 300-500ms).
///
/// How cookies flow:
///   - WKWebView's `WKWebsiteDataStore.default()` holds the GP session cookies
///   - URLSession.shared uses `HTTPCookieStorage.shared`
///   - We sync the .google.com cookies between the two before each fetch
///   - Google's `=dv` URL responds with the authenticated video bytes
///
/// Files live in a session-scoped tmp dir and are cleared via
/// `clearCache()` from GPSwipeView.onDisappear so the user's disk doesn't
/// fill up across many triage sessions.
@MainActor
final class VideoFilePrefetcher {
    static let shared = VideoFilePrefetcher()

    private var cachedFiles: [String: URL] = [:]   // remote.absoluteString → local file://
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []

    /// Pending swap callbacks: when a WebVideoPlayer mounts before its
    /// video has been prefetched, it subscribes here. Once the file is
    /// ready, we call back so the WebView can swap `<video src=…>` to the
    /// local URL.
    private var observers: [String: [(URL) -> Void]] = [:]

    private let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-cleaner-videos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    /// Returns a `pcvideo://` URL if the remote has been fully cached.
    /// WebVideoPlayer prefers this when present — the custom URL scheme
    /// handler reads bytes straight off disk and serves them as a
    /// video/mp4 response without the file://-from-https same-origin
    /// block that broke the previous file:// approach.
    func localURL(for remote: URL) -> URL? {
        guard let fileURL = cachedFiles[remote.absoluteString] else { return nil }
        return PCVideoSchemeHandler.url(for: fileURL)
    }

    /// Subscribe to be notified when `remote` is cached. Called by
    /// WebVideoPlayer when it mounts but the file isn't ready yet — so
    /// it can swap `<video src>` as soon as the file lands.
    ///
    /// IMPORTANT: callbacks receive the `pcvideo://` scheme URL, never the
    /// raw `file://` path. The player's page is on https://photos.google.com,
    /// and WebKit blocks file:// loads from https pages — a file:// swap
    /// replaces a slow-but-working remote stream with a permanently dead
    /// src (black card). That was the root cause of "videos occasionally
    /// don't play".
    func observe(_ remote: URL, callback: @escaping (URL) -> Void) {
        let key = remote.absoluteString
        // If already cached, fire synchronously.
        if let file = cachedFiles[key], let scheme = PCVideoSchemeHandler.url(for: file) {
            callback(scheme)
            return
        }
        observers[key, default: []].append(callback)
    }

    /// Start a background download. No-op if already cached, in flight, or
    /// known-failed. Optionally also prefetches a `posterURL` (thumbnail)
    /// via URLSession.shared so the bytes land in URLCache.shared — and
    /// SwiftUI AsyncImage displaying that URL hits cache instantly,
    /// eliminating the black-flash-before-video on first card render.
    func prefetch(_ remote: URL, posterURL: URL? = nil) {
        // Kick off poster prefetch independently — small image, fast,
        // no need to dedupe carefully (URLSession is happy with repeat
        // requests + URLCache makes them cheap).
        if let posterURL {
            Task.detached(priority: .userInitiated) {
                // Sync cookies first in case the poster URL needs auth.
                await Self.syncGoogleCookiesFromWebKit()
                // URLSession.shared uses URLCache.shared by default.
                // The response is automatically stored and SwiftUI's
                // AsyncImage will read from it next time.
                _ = try? await URLSession.shared.data(from: posterURL)
            }
        }

        let key = remote.absoluteString
        if cachedFiles[key] != nil { return }
        if inFlight.contains(key) { return }
        if failed.contains(key) { return }
        inFlight.insert(key)

        Task { [weak self] in
            await self?.download(remote: remote)
        }
    }

    private func download(remote: URL) async {
        let key = remote.absoluteString
        do {
            // 1. Copy WK cookies into the shared HTTPCookieStorage that
            //    URLSession.shared reads from. Without this Google 401s
            //    the =dv request because URLSession is "anonymous".
            await Self.syncGoogleCookiesFromWebKit()

            // 2. Download STREAMING TO DISK. download(from:) writes to a
            //    temp file as bytes arrive — data(from:) buffered whole
            //    videos in RAM, and 4K =dv originals can be hundreds of
            //    MB. With 4 prefetches + 3 live WebViews that risked
            //    jetsam on device.
            let (tmpURL, response) = try await URLSession.shared.download(from: remote)

            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: tmpURL)
                markFailed(key)
                return
            }

            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            // If we get back image bytes instead of video, the entry was
            // actually a photo — mark failed so we don't retry, and
            // WebVideoPlayer's onerror still falls back to poster.
            guard mime.hasPrefix("video/") else {
                try? FileManager.default.removeItem(at: tmpURL)
                markFailed(key)
                return
            }

            // 3. Move into our cache dir with a stable name.
            let ext: String
            if mime.contains("mp4") { ext = "mp4" }
            else if mime.contains("quicktime") || mime.contains("mov") { ext = "mov" }
            else if mime.contains("webm") { ext = "webm" }
            else { ext = "mp4" }
            // SHA-ish stable filename from URL hash so re-prefetch finds
            // the same path.
            let filename = "v_\(abs(key.hashValue)).\(ext)"
            let fileURL = tempDir.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tmpURL, to: fileURL)

            cachedFiles[key] = fileURL
            inFlight.remove(key)

            // 4. Notify any waiters — with the pcvideo:// URL, NOT the
            //    raw file:// path (see observe() for why).
            if let cbs = observers[key], let scheme = PCVideoSchemeHandler.url(for: fileURL) {
                observers[key] = nil
                for cb in cbs { cb(scheme) }
            }
        } catch {
            markFailed(key)
        }
    }

    private func markFailed(_ key: String) {
        failed.insert(key)
        inFlight.remove(key)
        // Drop pending observers — they keep their remote src.
        observers[key] = nil
    }

    /// Sync .google.com cookies from the WKWebView's cookie jar into
    /// HTTPCookieStorage.shared so URLSession.shared can authenticate.
    static func syncGoogleCookiesFromWebKit() async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let store = HTTPCookieStorage.shared
                for cookie in cookies {
                    let d = cookie.domain.lowercased()
                    if d == "google.com" || d.hasSuffix(".google.com") {
                        store.setCookie(cookie)
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Clear all cached video files. Hooked to GPSwipeView.onDisappear so
    /// the user's disk isn't filled by repeated triage sessions.
    func clearCache() {
        for url in cachedFiles.values {
            try? FileManager.default.removeItem(at: url)
        }
        cachedFiles.removeAll()
        inFlight.removeAll()
        failed.removeAll()
        observers.removeAll()
    }
}
