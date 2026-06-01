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
          /* Debug overlay — shows live video element state so we can
             diagnose autoplay/loading issues on real devices. Sits at
             the top of the card, doesn't block taps. */
          #pcDebug {
            position: absolute; top: 6px; left: 6px; right: 6px;
            background: rgba(0,0,0,0.78); color: #fff;
            padding: 5px 8px; border-radius: 6px;
            font-family: -apple-system, monospace; font-size: 10px;
            line-height: 1.3; pointer-events: none; z-index: 10;
            text-align: left; word-break: break-all;
          }
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
            <div id="pcDebug">init…</div>
          </div>
          <script>
            (function () {
              var v = document.getElementById('v');
              var p = document.getElementById('poster');
              var dbg = document.getElementById('pcDebug');
              var lines = [];
              function log(msg) {
                lines.push(msg);
                if (lines.length > 6) lines.shift();
                if (dbg) dbg.textContent = lines.join('\\n');
              }

              // Show what URL the video is using (truncated). pcvideo:// =
              // prefetched local file (fast). https = remote fetch (slow,
              // depends on cookies reaching the WebView).
              var srcStr = v.currentSrc || v.src || '';
              var srcShort = srcStr.length > 70 ? srcStr.substring(0, 70) + '…' : srcStr;
              log('src: ' + srcShort);
              log('ua hint: ' + navigator.platform);

              function hidePoster() {
                if (p && !p.classList.contains('hidden')) p.classList.add('hidden');
              }

              v.addEventListener('loadstart',     function () { log('loadstart'); });
              v.addEventListener('loadedmetadata', function () { log('metadata: ' + v.videoWidth + 'x' + v.videoHeight); });
              v.addEventListener('loadeddata',    function () { log('loadeddata'); v.play().catch(function(e){ log('play() rejected: ' + e.message); }); });
              v.addEventListener('canplay',       function () { log('canplay'); v.play().catch(function(e){ log('play() rejected: ' + e.message); }); });
              v.addEventListener('playing',       function () { log('PLAYING'); hidePoster(); });
              v.addEventListener('timeupdate',    function () { hidePoster(); });
              v.addEventListener('stalled',       function () { log('stalled (readyState=' + v.readyState + ')'); });
              v.addEventListener('waiting',       function () { log('waiting (readyState=' + v.readyState + ')'); });
              v.addEventListener('suspend',       function () { log('suspend'); });
              v.addEventListener('error', function () {
                var err = v.error;
                var msg = 'unknown';
                if (err) {
                  switch (err.code) {
                    case 1: msg = '1 ABORTED'; break;
                    case 2: msg = '2 NETWORK'; break;
                    case 3: msg = '3 DECODE'; break;
                    case 4: msg = '4 SRC_NOT_SUPPORTED'; break;
                    default: msg = String(err.code);
                  }
                  if (err.message) msg += ' (' + err.message + ')';
                }
                log('ERROR: ' + msg);
              });

              // Aggressive autoplay kicks — iOS Safari sometimes ignores
              // the autoplay attribute until the first frame is decoded.
              setTimeout(function () { v.play().catch(function(e){ log('kick100 rejected: ' + e.message); }); }, 100);
              setTimeout(function () { v.play().catch(function(e){ log('kick500 rejected: ' + e.message); }); }, 500);
              setTimeout(function () { v.play().catch(function(e){ log('kick1500 rejected: ' + e.message); }); }, 1500);

              // Tap anywhere on the stage to try playing — gives the
              // user an escape hatch if autoplay is blocked.
              document.body.addEventListener('click', function () {
                log('tap → play()');
                v.play().catch(function(e){ log('tap-play rejected: ' + e.message); });
              });
            })();
          </script>
        </body></html>
        """
    }
}
