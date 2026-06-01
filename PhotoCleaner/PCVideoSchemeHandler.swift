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

        do {
            let data = try Data(contentsOf: fileURL)
            let mime: String
            switch fileURL.pathExtension.lowercased() {
            case "mp4":  mime = "video/mp4"
            case "mov":  mime = "video/quicktime"
            case "m4v":  mime = "video/x-m4v"
            case "webm": mime = "video/webm"
            default:     mime = "video/mp4"
            }
            let headers: [String: String] = [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Accept-Ranges": "bytes",
                "Cache-Control": "no-store"
            ]
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No streaming/cancellation state to clean up — we serve the
        // whole file synchronously in `start`.
    }
}
