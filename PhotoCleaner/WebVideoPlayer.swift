import SwiftUI
import WebKit

/// A tiny WKWebView wrapping an HTML5 `<video>` tag. Each instance owns its
/// own WKWebView — the brief "shared-pool" experiment was reverted because
/// SwiftUI's UIViewRepresentable lifecycle doesn't cleanly support a single
/// UIView being shared across multiple representable instances (state from
/// offscreen-paused WebViews bled into visible ones, leaving cards black).
///
/// Why WKWebView instead of AVPlayer:
///   - GP's `=dv` URLs serve authenticated cross-origin redirects.
///     AVURLAssetHTTPHeaderFieldsKey does NOT propagate cookies through
///     these redirects, so AVPlayer's anonymous URLSession got 401'd.
///   - WKWebView with `WKWebsiteDataStore.default()` shares the cookie
///     jar with the main GP WebView, so HTTP fetches in this player are
///     authenticated the same way Chrome does it.
///
/// What we get for instant-ish playback:
///   - HTML `<video preload="auto">` starts streaming the URL the moment
///     the WebView's first paint happens.
///   - In parallel a JS `fetch(URL, {credentials:'include'})` downloads
///     the full asset into a Blob. Once ready, video.src is swapped to
///     the blob:// URL so loops + seeks play from memory.
///
/// The remaining ~1s on first-card load is just network latency — that's
/// the limit of doing per-instance loading. True cross-card prefetching
/// would need a custom UIViewController-based player or a server proxy.
struct WebVideoPlayer: UIViewRepresentable {
    let videoURL: URL
    let posterURL: URL?

    /// One shared WKProcessPool across all video WebViews. This is what
    /// makes "offscreen prefetch" actually accelerate playback: when a
    /// hidden prefetch WebView loads video URL X, the bytes go into the
    /// shared HTTP cache. When the visible WebView later requests the
    /// same URL, the request is served from cache and playback starts
    /// nearly instantly. (Pre-pool, each WebView had its own URL cache
    /// and prefetched bytes never carried over.)
    @MainActor
    private static let sharedProcessPool = WKProcessPool()

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Shared process pool → shared HTTP cache across all video
        // WebView instances. The single most impactful change for
        // perceived video speed: prefetched bytes are reused.
        config.processPool = WebVideoPlayer.sharedProcessPool
        // Shared cookie jar with the main GP WebView — critical for
        // authenticating to Google's media endpoints.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Register the pcvideo:// URL scheme so prefetched local files
        // can be played by the HTML5 <video> element. Without this, the
        // file:// approach would be blocked by WKWebView's same-origin
        // policy (page is on https://photos.google.com).
        config.setURLSchemeHandler(PCVideoSchemeHandler(), forURLScheme: PCVideoSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Transparent surface — the GPSwipeView ZStack puts an AsyncImage
        // backdrop behind every video card, so the user sees the poster
        // immediately (URLSession prefetches the URL into URLCache before
        // the WebView even mounts). Once the video plays, its opaque
        // pixels cover the backdrop. Eliminates the black-flash that
        // happened during HTML parse + video network fetch.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // Path B: if the video was prefetched to a local tmp file, use
        // its file:// URL — playback starts essentially as fast as the
        // hardware decoder spins up (~50-100ms). No network roundtrip,
        // no =dv redirect chain. Remote URL is the slow-path fallback.
        let initialURL = VideoFilePrefetcher.shared.localURL(for: videoURL) ?? videoURL
        webView.loadHTMLString(buildHTML(videoURL: initialURL, posterURL: posterURL),
                               baseURL: URL(string: "https://photos.google.com/"))

        // Subscribe so we can swap to the local file even if the
        // prefetch finishes AFTER the visible WebView mounts (rare race
        // — user lands on a card just as its prefetch is in flight).
        if VideoFilePrefetcher.shared.localURL(for: videoURL) == nil {
            VideoFilePrefetcher.shared.observe(videoURL) { [weak webView] localURL in
                guard let webView else { return }
                let escaped = localURL.absoluteString
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let js = """
                  (function () {
                    var v = document.getElementById('v');
                    if (!v) return;
                    if (v.readyState >= 3) return;
                    var t = v.currentTime || 0;
                    v.src = "\(escaped)";
                    v.currentTime = t;
                    v.play().catch(function () {});
                  })();
                """
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Kick the video to play on every SwiftUI update — covers cases
        // where iOS pauses the WebView when its host view becomes
        // temporarily detached during a swipe transition.
        uiView.evaluateJavaScript(
            "var v=document.getElementById('v'); if(v){v.play().catch(function(){});}",
            completionHandler: nil
        )
    }

    private func buildHTML(videoURL: URL, posterURL: URL?) -> String {
        let videoEscaped = videoURL.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let posterTag: String
        if let posterURL {
            let p = posterURL.absoluteString
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            posterTag = "<img class=\"poster\" id=\"poster\" src=\"\(p)\">"
        } else {
            posterTag = ""
        }

        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <style>
          /* All transparent — the SwiftUI AsyncImage backdrop behind
             the WebView is what the user sees until the <video> element
             paints its first frame. Black-flash eliminated. */
          :root { color-scheme: dark; background: transparent; }
          html, body {
            margin: 0; padding: 0; height: 100%; width: 100%;
            background: transparent; overflow: hidden;
            -webkit-tap-highlight-color: transparent;
          }
          .stage {
            position: relative; width: 100%; height: 100%;
            display: flex; align-items: center; justify-content: center;
            background: transparent;
          }
          video {
            width: 100%; height: 100%;
            object-fit: contain;
            background: transparent;
            outline: none;
          }
          video::-webkit-media-controls,
          video::-webkit-media-controls-panel,
          video::-webkit-media-controls-enclosure,
          video::-webkit-media-controls-start-playback-button {
            display: none !important;
            -webkit-appearance: none !important;
          }
          img.poster {
            position: absolute; inset: 0;
            width: 100%; height: 100%;
            object-fit: contain;
            background: transparent;
            transition: opacity 80ms linear;
            pointer-events: none;
          }
          .hidden { opacity: 0 !important; }
        </style>
        </head><body>
          <div class="stage">
            \(posterTag)
            <video id="v"
              autoplay loop muted playsinline preload="auto"
              webkit-playsinline
              x-webkit-airplay="deny"
              disableRemotePlayback
              src="\(videoEscaped)"></video>
          </div>
          <script>
            (function () {
              var v = document.getElementById('v');
              var p = document.getElementById('poster');
              function hidePoster() {
                if (p && !p.classList.contains('hidden')) p.classList.add('hidden');
              }
              v.addEventListener('playing', hidePoster);
              v.addEventListener('timeupdate', hidePoster);
              v.addEventListener('canplay', function () { v.play().catch(function(){}); });
              v.addEventListener('loadeddata', function () { v.play().catch(function(){}); });

              // Aggressive autoplay kicks — iOS Safari sometimes ignores
              // the autoplay attribute until the first frame is decoded.
              setTimeout(function () { v.play().catch(function () {}); }, 100);
              setTimeout(function () { v.play().catch(function () {}); }, 500);
              setTimeout(function () { v.play().catch(function () {}); }, 1500);

              // Tap-as-fallback: if autoplay was blocked, tapping the
              // card kicks playback.
              document.body.addEventListener('click', function () {
                v.play().catch(function () {});
              });
            })();
          </script>
        </body></html>
        """
    }
}
