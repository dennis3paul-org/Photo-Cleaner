import Foundation
import WebKit

/// A custom WKURLSchemeHandler that serves cached video files via
/// `pcvideo://` URLs. We need this because:
///
///   - We want WKWebView to play prefetched videos from local tmp files
///     (Path B from the Chrome extension's playbook)
///   - But the WebView's page is loaded with a `https://photos.google.com/`
///     baseURL (so cookies + same-origin policy match GP)
///   - And `<video src="file://...">` is BLOCKED by WebKit when the page
///     is on https — the cross-origin policy applies to file:// just
///     like any other scheme
///   - And the `allowFileAccessFromFileURLs` private preference is risky
///     for App Store distribution
///
/// A custom scheme bypasses the issue cleanly: WebKit treats `pcvideo://`
/// as a separate origin (no same-origin issues for the page), and our
/// handler reads bytes off disk + returns a properly-typed response.
///
/// URL format: `pcvideo://load/<percent-encoded-tmp-relative-path>`
///   e.g. `pcvideo://load/v_8675309.mp4`
/// We restrict reads to the VideoFilePrefetcher's tmp dir so this
/// handler can't be abused to read arbitrary disk paths.
final class PCVideoSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pcvideo"

    /// Convert a local file URL (in VideoFilePrefetcher's tmp dir) into
    /// a `pcvideo://` URL that the handler can resolve back. Only the
    /// last path component is exposed in the URL — full disk paths
    /// stay private.
    static func url(for fileURL: URL) -> URL? {
        let name = fileURL.lastPathComponent
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return URL(string: "\(scheme)://load/\(encoded)")
    }

    private static var tmpDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-cleaner-videos")
    }

    /// Tasks WebKit has cancelled via `stop`. Calling didReceive/didFinish
    /// on a stopped task crashes with an NSInternalInconsistencyException,
    /// and our disk read completes asynchronously — so every callback into
    /// the task first checks this set. Guarded by `stateLock` because
    /// start/stop arrive on the main thread while the disk read finishes
    /// on the IO queue.
    private var stoppedTasks = Set<ObjectIdentifier>()
    private let stateLock = NSLock()

    /// Serial background queue for disk reads. The previous version did
    /// Data(contentsOf:) synchronously in start — WKURLSchemeHandler
    /// callbacks arrive on the main thread, so serving a large cached
    /// video stalled the UI right as its card became visible.
    private let ioQueue = DispatchQueue(label: "pcvideo.io", qos: .userInitiated)

    private func isStopped(_ task: WKURLSchemeTask) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stoppedTasks.contains(ObjectIdentifier(task))
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Extract the last path component (the file name in the tmp dir).
        let name = url.lastPathComponent
        guard !name.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let fileURL = Self.tmpDir.appendingPathComponent(name)

        // Sandbox: only serve files actually inside our tmp dir. Prevents
        // path-traversal abuse via `..` components.
        let resolvedFile = fileURL.standardizedFileURL
        let resolvedRoot = Self.tmpDir.standardizedFileURL
        guard resolvedFile.path.hasPrefix(resolvedRoot.path) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")

        ioQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<(Data, HTTPURLResponse), Error> = Self.buildResponse(
                url: url, fileURL: fileURL, rangeHeader: rangeHeader
            )
            // WKURLSchemeTask methods must be called on the thread the
            // handler was invoked on (main).
            DispatchQueue.main.async {
                guard !self.isStopped(urlSchemeTask) else {
                    // Task is dead — drop its bookkeeping entry so the
                    // stopped set doesn't grow across a long session.
                    self.stateLock.lock()
                    self.stoppedTasks.remove(ObjectIdentifier(urlSchemeTask))
                    self.stateLock.unlock()
                    return
                }
                switch result {
                case .success(let (body, response)):
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(body)
                    urlSchemeTask.didFinish()
                case .failure(let error):
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }

    /// Read the file (memory-mapped, so a 300MB video doesn't copy into
    /// RAM) and honor Range requests with a 206 — the <video> element's
    /// loop/seek path issues `Range: bytes=N-` requests, and answering
    /// them with a full 200 body forced WebKit to re-buffer the whole
    /// file on every loop iteration.
    private static func buildResponse(
        url: URL, fileURL: URL, rangeHeader: String?
    ) -> Result<(Data, HTTPURLResponse), Error> {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            return .failure(error)
        }

        let mime: String
        switch fileURL.pathExtension.lowercased() {
        case "mp4":  mime = "video/mp4"
        case "mov":  mime = "video/quicktime"
        case "m4v":  mime = "video/x-m4v"
        case "webm": mime = "video/webm"
        default:     mime = "video/mp4"
        }

        let total = data.count
        var status = 200
        var body = data
        var headers: [String: String] = [
            "Content-Type": mime,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store"
        ]

        // Parse "bytes=start-end" (end optional). Malformed → serve 200.
        if let rangeHeader,
           let match = rangeHeader.range(of: #"bytes=(\d*)-(\d*)"#, options: .regularExpression) {
            let spec = String(rangeHeader[match]).dropFirst("bytes=".count)
            let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let start = parts.count > 0 ? Int(parts[0]) : nil
            let end = parts.count > 1 ? Int(parts[1]) : nil
            if let s = start, s < total {
                let e = min(end ?? total - 1, total - 1)
                if s <= e {
                    status = 206
                    body = data.subdata(in: s..<(e + 1))
                    headers["Content-Range"] = "bytes \(s)-\(e)/\(total)"
                }
            }
        }
        headers["Content-Length"] = String(body.count)

        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            return .failure(URLError(.cannotParseResponse))
        }
        return .success((body, response))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stateLock.lock()
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
        stateLock.unlock()
    }
}
