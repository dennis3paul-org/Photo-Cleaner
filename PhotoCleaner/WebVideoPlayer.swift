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
    /// Increment to force an immediate play() kick — wired to a SwiftUI
    /// tap gesture on the card. Needed because the WebView itself has
    /// .allowsHitTesting(false) (so drags feel native), which makes the
    /// in-page tap-to-play listener unreachable. Low Power Mode blocks
    /// autoplay at the system level, so a user-initiated kick path must
    /// exist.
    var playKick: Int = 0

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Shared cookie jar + HTTP cache with the main GP WebView —
        // critical for authenticating to Google's media endpoints, and
        // what lets prefetched bytes be reused across player instances.
        // (WKProcessPool sharing was removed: it's been a no-op since
        // iOS 15 — the websiteDataStore governs cache sharing.)
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastKickTime: TimeInterval = 0
        var lastPlayKick: Int = 0
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Kick the video to play on SwiftUI updates — covers cases where
        // iOS pauses the WebView when its host view becomes temporarily
        // detached during a swipe transition.
        //
        // THROTTLED: during a drag, SwiftUI re-renders the card at
        // 60-120Hz and each render used to fire an evaluateJavaScript
        // round-trip into the web process — main-thread + IPC churn that
        // directly worked against swipe smoothness. Now at most one kick
        // per 300ms, except an explicit playKick bump (user tapped the
        // card) which always fires immediately.
        let now = ProcessInfo.processInfo.systemUptime
        let kicked = playKick != context.coordinator.lastPlayKick
        guard kicked || now - context.coordinator.lastKickTime > 0.3 else { return }
        context.coordinator.lastKickTime = now
        context.coordinator.lastPlayKick = playKick
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

              // Stall recovery: if the network fetch wedges (redirect
              // hiccup, cookie race, cell handoff), re-kick the whole
              // load pipeline — up to 2 times so a genuinely dead URL
              // doesn't loop forever.
              var reloadTries = 0;
              function recover() {
                if (reloadTries >= 2) return;
                reloadTries++;
                try { v.load(); } catch (e) {}
                v.play().catch(function () {});
              }
              v.addEventListener('stalled', function () { setTimeout(recover, 1200); });
              v.addEventListener('error', function () { setTimeout(recover, 400); });

              // Aggressive autoplay kicks — iOS Safari sometimes ignores
              // the autoplay attribute until the first frame is decoded.
              // Longer tail (3s/5s) covers slow =dv redirect chains on
              // cell connections.
              [100, 500, 1500, 3000, 5000].forEach(function (ms) {
                setTimeout(function () {
                  if (v.paused) v.play().catch(function () {});
                }, ms);
              });

              // Tap-as-fallback: if autoplay was blocked, tapping the
              // card kicks playback. (Reached via the SwiftUI playKick
              // path — the WebView itself doesn't get touches.)
              document.body.addEventListener('click', function () {
                v.play().catch(function () {});
              });
            })();
          </script>
        </body></html>
        """
    }
}
