import SwiftUI
import WebKit

/// One photo harvested from the rendered photos.google.com DOM.
struct GPPhoto: Identifiable, Hashable, Codable {
    let id: String        // The /photo/<id> path component.
    let thumbURL: String  // lh3.googleusercontent.com URL from the <img>.
    let label: String     // The anchor's aria-label (filename + date if present).
    /// File size in bytes when EzkLib exposed it (0 if unknown — DOM-harvested
    /// photos and old entries without size metadata).
    var sizeBytes: Int64 = 0

    var isVideo: Bool {
        let l = label.lowercased()
        return l.hasPrefix("video") || l.contains(" video ") || l.contains("video -")
    }

    /// Extracts "Month Day, Year" from the aria-label so we can query GP's
    /// EzkLib date-search RPC. The label format from GP is e.g.:
    ///   "Photo - Portrait - May 23, 2026, 4:32:54 PM"
    /// Returns nil when the label has no date — those photos will be skipped
    /// in cleanup with a clear error.
    var dateString: String? {
        let pattern = #"([A-Z][a-z]+\s+\d+,\s+\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(label.startIndex..., in: label)
        guard
            let match = regex.firstMatch(in: label, range: range),
            let r = Range(match.range(at: 1), in: label)
        else { return nil }
        return String(label[r])
    }

    /// Card-sized display URL: rewrites the GP CDN size suffix to request
    /// a larger image (=w1200-h1200). Shared by the swipe-card backdrop
    /// and the poster pre-warm path — both MUST derive the same URL or
    /// the URLCache prefetch never hits.
    var enlargedURL: URL? {
        var url = thumbURL
        url = url.replacingOccurrences(
            of: #"=w\d+-h\d+"#, with: "=w1200-h1200", options: .regularExpression
        )
        url = url.replacingOccurrences(
            of: #"=s\d+"#, with: "=s1200", options: .regularExpression
        )
        return URL(string: url)
    }

    /// The video URL handed to WebVideoPlayer. `=dv` is GP's own
    /// download-video format — what GP's web player itself requests.
    /// The shared WKWebsiteDataStore cookie jar authenticates the
    /// redirect chain the same way Chrome does.
    var videoURL: URL? {
        let widthHeight = #"=w\d+-h\d+(?:-[a-z])?(?:-no)?"#
        let square = #"=s\d+(?:-[a-z])?(?:-no)?"#
        var s = thumbURL
        s = s.replacingOccurrences(of: widthHeight, with: "=dv", options: .regularExpression)
        s = s.replacingOccurrences(of: square, with: "=dv", options: .regularExpression)
        return URL(string: s)
    }
}

enum GPError: LocalizedError {
    case webViewMissing
    case jsThrew(String)
    case unexpectedResult

    var errorDescription: String? {
        switch self {
        case .webViewMissing: return "Web view is not ready"
        case .jsThrew(let m): return m
        case .unexpectedResult: return "Unexpected response from page"
        }
    }
}

/// Imperative handle on the WKWebView so SwiftUI can drive navigation, harvest
/// visible photos, and invoke the trash RPC. Holds the webView with a STRONG
/// reference so it survives across SwiftUI view lifetimes — the controller
/// is owned at app level (AppModel) and the WebView's loaded page/cookies/
/// scroll-position persist across multiple visits to GooglePhotosView.
@MainActor
final class GooglePhotosWebController: ObservableObject {
    fileprivate var webView: WKWebView?
    @Published private(set) var harvested: [GPPhoto] = []

    init() {
        loadCachedRJ0()
    }

    /// Total media-item count for the signed-in GP account (photos + videos).
    /// Updated automatically when our document-start sniffer captures
    /// Google's `rJ0tlb` RPC response (which fires during GP page
    /// bootstrap). IdleView observes this via @Published.
    @Published private(set) var libraryTotal: Int?
    /// rJ0tlb date bounds (oldest + newest ms in the user's library).
    /// Used by gpRandomBatchByDate to pick uniform-random dates.
    @Published private(set) var oldestMs: Int64?
    @Published private(set) var newestMs: Int64?
    /// Surfaced for debugging when capture fails entirely. The eNG3nf
    /// fallback path was removed — Google returns PERMISSION_DENIED ([3])
    /// for non-first-party callers, no amount of body tweaking helps.
    @Published private(set) var libraryTotalError: String?

    /// Track whether we already issued the "no rJ0tlb yet → reload" nudge
    /// so we don't loop forever if rJ0tlb still doesn't fire.
    private var nudgePerformed = false
    func markNudgePerformed() { nudgePerformed = true }
    /// Read by the navigation delegate before scheduling another nudge —
    /// without this check every didFinish with no captured rJ0tlb queued
    /// another reload, which was an infinite reload loop whenever the
    /// capture/parse kept failing (visible as the page randomly reloading
    /// out from under the user every few seconds).
    var hasNudged: Bool { nudgePerformed }

    private static let kCachedRJ0Key = "pc_rj0_snapshot_v1"
    private static let cacheTTL: TimeInterval = 60 * 60  // 1h

    /// Hydrate from UserDefaults — call once at construction. Until rJ0tlb
    /// re-fires this session, IdleView shows the cached count immediately
    /// instead of "Connecting…".
    private func loadCachedRJ0() {
        guard let data = UserDefaults.standard.data(forKey: Self.kCachedRJ0Key),
              let entry = try? JSONDecoder().decode(CachedRJ0.self, from: data),
              Date().timeIntervalSince1970 - entry.savedAt < Self.cacheTTL
        else { return }
        libraryTotal = entry.count
        oldestMs = entry.oldestMs
        newestMs = entry.newestMs
    }

    private func saveCachedRJ0() {
        guard let count = libraryTotal,
              let oldest = oldestMs,
              let newest = newestMs else { return }
        let entry = CachedRJ0(
            count: count, oldestMs: oldest, newestMs: newest,
            savedAt: Date().timeIntervalSince1970
        )
        if let data = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(data, forKey: Self.kCachedRJ0Key)
        }
    }

    private struct CachedRJ0: Codable {
        let count: Int
        let oldestMs: Int64
        let newestMs: Int64
        let savedAt: TimeInterval
    }

    /// Parse a raw rJ0tlb response body (sent from the JS sniffer via
    /// messageHandlers). Updates libraryTotal + oldestMs + newestMs and
    /// persists to UserDefaults. Tolerant: failures don't clear existing
    /// state, they just stash a diagnostic in libraryTotalError.
    func ingestRJ0Response(rawText: String) {
        guard let parsed = Self.parseRJ0tlb(rawText) else {
            // Store the head of the response so the user-facing error
            // sheet can surface it for debugging.
            let head = String(rawText.prefix(600))
                .replacingOccurrences(of: "\n", with: " ")
            libraryTotalError = "rJ0tlb parse failed | head: \(head)"
            return
        }
        libraryTotal = parsed.count
        oldestMs = parsed.oldestMs
        newestMs = parsed.newestMs
        libraryTotalError = nil
        saveCachedRJ0()
    }

    private struct ParsedRJ0 {
        let count: Int
        let oldestMs: Int64
        let newestMs: Int64
    }

    /// Pure-Swift rJ0tlb parser. Format from Google:
    ///   )]}'
    ///   <chunkLen>
    ///   [["wrb.fr","rJ0tlb","[<count>,[[<startMs>,<endMs>,<count>,<flag>],...]]",null,null,N,"generic"],...]
    /// The inner JSON-encoded string at position 2 has total count first,
    /// then a histogram of date buckets. Sentinel timestamps (Google
    /// uses -62170156000 to mean "unknown date") are filtered out by a
    /// plausibility clamp.
    private static func parseRJ0tlb(_ text: String) -> ParsedRJ0? {
        // Find the wrb.fr frame for rJ0tlb specifically (response may be
        // a batched response containing multiple RPCs).
        let marker = "\"wrb.fr\",\"rJ0tlb\",\""
        guard let markerRange = text.range(of: marker) else { return nil }

        // Extract the escaped JSON string between the marker and the next
        // unescaped quote.
        var escaped = ""
        var idx = markerRange.upperBound
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "\\" {
                escaped.append(ch)
                let next = text.index(after: idx)
                if next < text.endIndex {
                    escaped.append(text[next])
                    idx = text.index(after: next)
                    continue
                }
                idx = next
                continue
            }
            if ch == "\"" { break }
            escaped.append(ch)
            idx = text.index(after: idx)
        }
        if escaped.isEmpty { return nil }

        // Wrap and JSON-parse the escaped string to get the actual inner
        // JSON text, then parse THAT to get the payload object.
        let quoted = "\"\(escaped)\""
        guard
            let stringData = quoted.data(using: .utf8),
            let innerString = try? JSONSerialization.jsonObject(with: stringData,
                                                                options: [.fragmentsAllowed]) as? String,
            let innerData = innerString.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: innerData, options: [])
        else { return nil }

        return parseRJ0Payload(payload)
    }

    /// Walk the parsed payload to find total count + histogram.
    /// Layout: payload[0] = totalCount (number), payload[1] = histogram
    /// (array of [startMs, endMs, count, flag]). We also recurse defensively
    /// in case GP rotates fields.
    private static func parseRJ0Payload(_ payload: Any) -> ParsedRJ0? {
        var total: Int?
        var hist: [[Any]]?

        if let arr = payload as? [Any] {
            // Walk top-level array for a leading number (count) and a
            // nested array-of-arrays (histogram).
            for item in arr {
                if total == nil, let n = item as? NSNumber {
                    let intVal = n.intValue
                    if intVal > 0 && intVal < 10_000_000 { total = intVal }
                }
                if hist == nil, let candidate = item as? [[Any]],
                   candidate.first?.count ?? 0 >= 3 {
                    hist = candidate
                }
                if total != nil && hist != nil { break }
            }
        }

        // Recursive fallback for the histogram if a shallow scan missed.
        if hist == nil { hist = findHistogramRecursive(payload, depth: 0) }
        guard let buckets = hist else { return nil }

        // Plausibility clamp: filter sentinel -62170156000 (Google's
        // "unknown date" sentinel). Real photos span roughly 1990..2100.
        let minPlausibleMs: Int64 = 631_152_000_000   // 1990-01-01
        let maxPlausibleMs: Int64 = 4_102_444_800_000 // 2100-01-01

        var oldest: Int64 = .max
        var newest: Int64 = .min
        var bucketTotal = 0
        for b in buckets {
            guard b.count >= 3 else { continue }
            if let s = b[0] as? NSNumber {
                let v = s.int64Value
                if v >= minPlausibleMs && v <= maxPlausibleMs {
                    if v < oldest { oldest = v }
                }
            }
            if let e = b[1] as? NSNumber {
                let v = e.int64Value
                if v >= minPlausibleMs && v <= maxPlausibleMs {
                    if v > newest { newest = v }
                }
            }
            if let c = b[2] as? NSNumber {
                bucketTotal += c.intValue
            }
        }
        guard oldest != .max, newest != .min, newest > oldest else { return nil }

        // Prefer the top-level total if Google supplied one; otherwise
        // sum the histogram bucket counts (less reliable but workable).
        let count = total ?? bucketTotal
        guard count > 0 else { return nil }

        return ParsedRJ0(count: count, oldestMs: oldest, newestMs: newest)
    }

    private static func findHistogramRecursive(_ node: Any, depth: Int) -> [[Any]]? {
        if depth > 25 { return nil }
        guard let arr = node as? [Any] else { return nil }
        if let first = arr.first as? [Any],
           first.count >= 3,
           let a = first[0] as? NSNumber,
           let _ = first[1] as? NSNumber,
           let _ = first[2] as? NSNumber,
           a.int64Value > 1_100_000_000_000,
           a.int64Value < 4_100_000_000_000 {
            return arr as? [[Any]]
        }
        for item in arr {
            if let r = findHistogramRecursive(item, depth: depth + 1) {
                return r
            }
        }
        return nil
    }

    /// Snapshot of the underlying WebView's current navigation state. Used
    /// by GooglePhotosView on appear to sync its @State (e.g. so the
    /// toolbar shows "Reload" not "Sign in" when re-attaching to a cached
    /// WebView that's already on photos.google.com).
    var currentLoadedURL: URL? { webView?.url }
    var currentPageTitle: String? { webView?.title }

    func reload() {
        webView?.reload()
    }

    func navigateToSignIn() {
        guard let url = URL(string: Self.signInURLString) else { return }
        webView?.load(URLRequest(url: url))
    }

    /// Runs the harvester JS in the page and returns the visible photos.
    @discardableResult
    func harvest() async -> [GPPhoto] {
        guard let webView else { return [] }
        do {
            let raw = try await webView.evaluateJavaScript("window.__photoCleanerHarvest && window.__photoCleanerHarvest()")
            let photos = Self.decodeHarvest(raw)
            harvested = photos
            return photos
        } catch {
            harvested = []
            return []
        }
    }

    /// Count of photos GP currently considers selected. Combines GP's header
    /// text ("N selected") and a scan for anchors with selected markers,
    /// returning the higher of the two.
    func gpSelectedCount() async -> Int {
        guard let webView else { return 0 }
        do {
            let raw = try await webView.evaluateJavaScript("window.__photoCleanerGPSelectedCount && window.__photoCleanerGPSelectedCount()")
            return (raw as? Int) ?? 0
        } catch {
            return 0
        }
    }

    /// Actual photo records for whatever GP has marked as selected.
    func gpGetSelected() async -> [GPPhoto] {
        guard let webView else { return [] }
        do {
            let raw = try await webView.evaluateJavaScript("window.__photoCleanerGPGetSelected && window.__photoCleanerGPGetSelected()")
            return Self.decodeHarvest(raw)
        } catch {
            return []
        }
    }

    /// Deep version of gpGetSelected that scrolls the GP grid to materialize
    /// every selected anchor before harvesting. GP's grid is virtualized — a
    /// shallow scan only returns anchors currently rendered in the DOM, so
    /// if the user selected 35 photos across a long scroll history we'd
    /// otherwise only return the ~15 currently visible. This walks the
    /// scrollable region top-to-bottom, accumulating selected photos as GP
    /// streams them in, then restores the user's original scroll position.
    /// Stops early once we've collected at least `expectedCount` selections.
    func gpGetSelectedDeep() async -> [GPPhoto] {
        guard let webView else { return [] }
        do {
            let raw = try await webView.callAsyncJavaScript(
                "return await window.__photoCleanerGPGetSelectedDeep()",
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            return Self.decodeHarvest(raw)
        } catch {
            return []
        }
    }

    /// Diagnostic helper — surfaces both GP's header count and how many
    /// anchors we could find selected markers on. Used when the two diverge.
    func gpSelectionDebug() async -> String {
        guard let webView else { return "(no webview)" }
        do {
            let raw = try await webView.evaluateJavaScript("window.__photoCleanerGPSelectionDebug && window.__photoCleanerGPSelectionDebug()")
            guard let dict = raw as? [String: Any] else { return "(no result)" }
            var lines: [String] = []
            lines.append("Header count: \(dict["headerCount"] as? Int ?? -1)")
            lines.append("Anchors w/ marker (final): \(dict["anchorsFoundWithMarker"] as? Int ?? -1)")
            lines.append("Total photo anchors: \(dict["totalPhotoAnchors"] as? Int ?? -1)")
            lines.append("")
            lines.append("DOM marker counts on the whole page:")
            lines.append("  [aria-checked=true]:  \(dict["countAriaCheckedTrue"] as? Int ?? -1)")
            lines.append("  [aria-selected=true]: \(dict["countAriaSelectedTrue"] as? Int ?? -1)")
            lines.append("  [role=checkbox]:      \(dict["countRoleCheckbox"] as? Int ?? -1)")
            lines.append("  [role=checkbox][aria-checked=true]: \(dict["countRoleCheckboxChecked"] as? Int ?? -1)")
            lines.append("  [data-checked=true]:  \(dict["countDataCheckedTrue"] as? Int ?? -1)")
            lines.append("  input[checked]:       \(dict["countInputChecked"] as? Int ?? -1)")
            if let s = dict["sampleAriaChecked"] as? String {
                lines.append("")
                lines.append("First [aria-checked=true] element:")
                lines.append(s)
            }
            if let s = dict["sampleAriaSelected"] as? String {
                lines.append("")
                lines.append("First [aria-selected=true] element:")
                lines.append(s)
            }
            if let s = dict["sampleRoleCheckbox"] as? String {
                lines.append("")
                lines.append("First [role=checkbox] element:")
                lines.append(s)
            }
            return lines.joined(separator: "\n")
        } catch {
            return "debug threw: \(error.localizedDescription)"
        }
    }

    /// Calls Google's internal trash RPC for one photo, via JS we injected on
    /// page load. Returns when the deletion is confirmed (Google echoes the
    /// photo ID back in the response payload). Throws on any failure.
    func deletePhoto(_ photo: GPPhoto) async throws {
        guard let webView else { throw GPError.webViewMissing }
        // EzkLib needs the photo's creation date to scope the search. The
        // label we harvested usually has it; if not, we surface a clear
        // diagnostic so the user knows which photos GP gave us with no date.
        guard let dateString = photo.dateString, !dateString.isEmpty else {
            throw GPError.jsThrew("No date in aria-label for \(photo.id): \"\(photo.label)\"")
        }
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                "return await window.__photoCleanerDeleteSafe(photoId, dateString)",
                arguments: ["photoId": photo.id, "dateString": dateString],
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw GPError.jsThrew("WebView JS failed to invoke: \(error.localizedDescription)")
        }
        guard let dict = raw as? [String: Any] else {
            throw GPError.unexpectedResult
        }
        if dict["ok"] as? Bool == true { return }
        let msg = (dict["error"] as? String) ?? "unknown JS error"
        throw GPError.jsThrew(msg)
    }

    /// Snapshot of the JS-side bulk-delete progress global. Swift polls this
    /// while a bulk operation is in flight.
    struct BulkProgress {
        let done: Int
        let total: Int
        let failed: Int
        let lastError: String
        let phase: String       // "idle" | "init" | "prefetch" | "batchexecute" | "parallel" | "done"
        let durationMs: Int
        let callCount: Int
        let totalCallMs: Int
        let minCallMs: Int
        let maxCallMs: Int
    }

    /// Spawn a JS-side bulk delete with N parallel workers. Returns the final
    /// counts when *every* worker has drained the queue.
    func bulkDelete(photos: [GPPhoto], concurrency: Int = 6) async throws -> (succeeded: Int, failedIds: [String]) {
        guard let webView else { throw GPError.webViewMissing }
        // Each photo needs id + dateString for the EzkLib scoped search.
        // Photos with no parseable date are filtered out and reported as
        // failures up-front (saves a JS round-trip).
        var photoArgs: [[String: String]] = []
        var preFailed: [String] = []
        for p in photos {
            if let date = p.dateString, !date.isEmpty {
                photoArgs.append(["id": p.id, "dateString": date])
            } else {
                preFailed.append(p.id)
            }
        }
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                "return await window.__photoCleanerBulkDelete(photos, concurrency)",
                arguments: ["photos": photoArgs, "concurrency": concurrency],
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw GPError.jsThrew("Bulk delete invoke failed: \(error.localizedDescription)")
        }
        guard let dict = raw as? [String: Any],
              let ok = dict["ok"] as? Int,
              let failed = dict["failedIds"] as? [String]
        else { throw GPError.unexpectedResult }
        return (succeeded: ok, failedIds: failed + preFailed)
    }

    func bulkProgress() async -> BulkProgress {
        let empty = BulkProgress(
            done: 0, total: 0, failed: 0, lastError: "", phase: "idle",
            durationMs: 0, callCount: 0, totalCallMs: 0, minCallMs: 0, maxCallMs: 0
        )
        guard let webView else { return empty }
        do {
            let raw = try await webView.evaluateJavaScript(
                "window.__photoCleanerGetBulkProgress && window.__photoCleanerGetBulkProgress()"
            )
            guard let dict = raw as? [String: Any] else { return empty }
            return BulkProgress(
                done: dict["done"] as? Int ?? 0,
                total: dict["total"] as? Int ?? 0,
                failed: dict["failed"] as? Int ?? 0,
                lastError: dict["lastError"] as? String ?? "",
                phase: dict["phase"] as? String ?? "idle",
                durationMs: dict["durationMs"] as? Int ?? 0,
                callCount: dict["callCount"] as? Int ?? 0,
                totalCallMs: dict["totalCallMs"] as? Int ?? 0,
                minCallMs: dict["minCallMs"] as? Int ?? 0,
                maxCallMs: dict["maxCallMs"] as? Int ?? 0
            )
        } catch {
            return empty
        }
    }

    /// Visually remove tiles for the given photo IDs from the WebView's DOM.
    /// Pure animation + detach — does NOT reload the page. Combine with
    /// reloadKeepingScroll() once the bulk RPC has actually completed to
    /// fully eliminate the gaps left behind.
    func hideDeletedPhotos(_ ids: [String]) async {
        guard let webView, !ids.isEmpty else { return }
        _ = try? await webView.callAsyncJavaScript(
            "return window.__photoCleanerHideDeleted(ids)",
            arguments: ["ids": ids],
            in: nil,
            contentWorld: .page
        )
    }

    /// Reload the page after stashing the scroll position so the page comes
    /// back exactly where the user was. Used after a successful bulk RPC to
    /// clean up the gaps left in GP's absolutely-positioned grid. MUST NOT
    /// be called while the bulk RPC is in flight — it kills the fetch.
    func reloadKeepingScroll() async {
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.__photoCleanerReloadKeepingScroll && window.__photoCleanerReloadKeepingScroll()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    /// Drive GP's native trash workflow: deselect "keep" photos, click GP's
    /// own trash button, click the confirmation dialog. GP handles the rest
    /// natively — internal state update + animated grid reflow + scroll
    /// preserved. No reload needed. Returns nil on success; an error string
    /// on failure (so the caller can fall back to XwAOJf).
    ///
    /// `expectedDeleteCount` is a safety net: the native path trashes
    /// whatever GP still has selected, and if the deep harvest collected
    /// fewer photos than the user actually selected, un-triaged photos
    /// would remain selected and get deleted. The JS verifies GP's own
    /// "N selected" header equals this count after deselecting keeps, and
    /// aborts (→ XwAOJf fallback, which deletes exactly the queue) on any
    /// mismatch.
    func deleteViaNativeUI(keepIds: [String], expectedDeleteCount: Int) async -> String? {
        guard let webView else { return "no web view" }
        do {
            let raw = try await webView.callAsyncJavaScript(
                "return await window.__photoCleanerDeleteViaGPUI(keepIds, expectedCount)",
                arguments: ["keepIds": keepIds, "expectedCount": expectedDeleteCount],
                in: nil,
                contentWorld: .page
            )
            guard let dict = raw as? [String: Any] else { return "unexpected result shape" }
            if dict["ok"] as? Bool == true { return nil }
            return (dict["error"] as? String) ?? "unknown GP UI failure"
        } catch {
            return "JS invoke failed: \(error.localizedDescription)"
        }
    }

    /// Harvest a *pool* of photos from GP by scrolling the grid until we've
    /// collected at least `targetCount` candidates (or hit the bottom of
    /// the library). Used by the random-pick feature — Swift then shuffles
    /// the pool and takes the requested N. Restores the user's original
    /// scroll position when done.
    func gpHarvestPool(targetCount: Int) async -> [GPPhoto] {
        guard let webView else { return [] }
        do {
            let raw = try await webView.callAsyncJavaScript(
                "return await window.__photoCleanerHarvestPool(targetCount)",
                arguments: ["targetCount": targetCount],
                in: nil,
                contentWorld: .page
            )
            return Self.decodeHarvest(raw)
        } catch {
            return []
        }
    }

    /// TRUE-random batch via EzkLib date sampling. Uses the sniffed rJ0tlb
    /// date histogram to pick random ms positions across the user's entire
    /// library lifespan, then calls EzkLib per date. Returns up to
    /// `targetCount` photos uniformly distributed across the library —
    /// not biased toward recent items the way the DOM harvester is.
    /// Returns nil + error string when rJ0tlb hasn't been sniffed yet.
    struct RandomBatchResult {
        let photos: [GPPhoto]
        let error: String?
    }
    func gpRandomBatchByDate(count: Int) async -> RandomBatchResult {
        guard let webView else {
            return RandomBatchResult(photos: [], error: "no webview")
        }
        guard let oldest = oldestMs, let newest = newestMs else {
            return RandomBatchResult(
                photos: [],
                error: "rJ0tlb bounds not captured yet"
            )
        }
        do {
            let raw = try await webView.callAsyncJavaScript(
                "return await window.__photoCleanerRandomBatchByDate(targetCount, oldestMs, newestMs)",
                arguments: [
                    "targetCount": count,
                    // JS Number safely holds integers up to 2^53; ms
                    // timestamps for 2026 are ~1.7e12, well under.
                    "oldestMs": Double(oldest),
                    "newestMs": Double(newest)
                ],
                in: nil,
                contentWorld: .page
            )
            guard let dict = raw as? [String: Any] else {
                return RandomBatchResult(photos: [], error: "unexpected JS result shape")
            }
            if dict["ok"] as? Bool == true,
               let photoDicts = dict["photos"] as? [[String: Any]] {
                let photos = Self.decodeHarvest(photoDicts)
                return RandomBatchResult(photos: photos, error: nil)
            }
            let err = (dict["error"] as? String) ?? "unknown error"
            return RandomBatchResult(photos: [], error: err)
        } catch {
            return RandomBatchResult(photos: [], error: "JS invoke: \(error.localizedDescription)")
        }
    }


    /// Manually request a page reload to force GP to re-bootstrap and
    /// re-fire rJ0tlb. Used by the "Retry" button on the error sheet and
    /// by the random-pill auto-wait if rJ0tlb still hasn't fired.
    /// (eNG3nf was removed: Google returns PERMISSION_DENIED `[3]` for
    /// non-first-party callers — no body shape ever made it work.)
    func forceRJ0Refresh() {
        nudgePerformed = true
        webView?.reload()
    }

    /// Wait up to `seconds` for rJ0tlb data to arrive. Used by the random
    /// pill so the user sees a "Bootstrapping…" state instead of an
    /// immediate failure alert when the count isn't ready yet.
    /// Returns true once both bounds are present, false on timeout.
    func waitForRJ0(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if oldestMs != nil, newestMs != nil { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return oldestMs != nil && newestMs != nil
    }

    /// Background pre-warm of the action-token cache. Called when triage
    /// starts so the bulk delete later doesn't have to wait on EzkLib.
    func prefetchActionTokens(for photos: [GPPhoto]) async {
        guard let webView else { return }
        let dates = Array(Set(photos.compactMap { $0.dateString }))
        guard !dates.isEmpty else { return }
        _ = try? await webView.callAsyncJavaScript(
            "return await window.__photoCleanerPrefetchDates(dates)",
            arguments: ["dates": dates],
            in: nil,
            contentWorld: .page
        )
    }

    /// Snapshots the page state so we can see WIZ availability + ID format
    /// without having to dig through DevTools. Returns a multi-line string
    /// suitable for direct display.
    func diagnose() async -> String {
        guard let webView else { return "(no web view)" }
        do {
            let raw = try await webView.evaluateJavaScript(
                "window.__photoCleanerDiagnose && window.__photoCleanerDiagnose()"
            )
            guard let dict = raw as? [String: Any] else {
                return "(could not decode diagnose result)"
            }
            var lines: [String] = []
            lines.append("URL: \(dict["pageURL"] as? String ?? "?")")
            lines.append("UA: \(dict["ua"] as? String ?? "?")")
            lines.append("Photo anchors: \(dict["anchorCount"] as? Int ?? 0)")
            lines.append("First href: \(dict["firstHref"] as? String ?? "(none)")")
            lines.append("First id: \(dict["firstId"] as? String ?? "(none)") (length \(dict["firstIdLength"] as? Int ?? 0))")
            lines.append("WIZ present: \(dict["wizPresent"] as? Bool ?? false)")
            lines.append("WIZ key count: \(dict["wizKeyCount"] as? Int ?? 0)")
            if let keys = dict["wizKeys"] as? [String] {
                lines.append("WIZ keys: \(keys.joined(separator: ","))")
            }
            lines.append("at (SNlM0e): \(dict["hasAtToken"] as? Bool ?? false)")
            lines.append("bl (cfb2h): \(dict["hasBlToken"] as? Bool ?? false)")
            lines.append("sid (FdrFJe): \(dict["hasSidToken"] as? Bool ?? false)")
            return lines.joined(separator: "\n")
        } catch {
            return "diagnose threw: \(error.localizedDescription)"
        }
    }

    private static func decodeHarvest(_ raw: Any?) -> [GPPhoto] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard
                let id = dict["id"] as? String, !id.isEmpty,
                let thumbURL = dict["thumbUrl"] as? String
            else { return nil }
            let label = (dict["label"] as? String) ?? ""
            let size = (dict["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            return GPPhoto(id: id, thumbURL: thumbURL, label: label, sizeBytes: size)
        }
    }

    static let signInURLString =
        "https://accounts.google.com/ServiceLogin?service=lh2&continue=https%3A%2F%2Fphotos.google.com%2F"
}

/// Hosts photos.google.com inside a WKWebView with persistent cookies and a
/// mobile Safari user-agent. Injects a JS bundle (harvester + delete RPC port
/// from the Chrome extension) at document end on every page load.
struct GooglePhotosWebView: UIViewRepresentable {
    let controller: GooglePhotosWebController
    @Binding var currentURL: URL?
    @Binding var pageTitle: String?
    @Binding var isLoading: Bool

    // Desktop Mac Safari 17 UA. We use desktop (not mobile) because Google's
    // internal Photos RPCs — VrseUb, XwAOJf, EzkLib — are scoped to the
    // desktop GP web app. The mobile-served photos.google.com bundle uses a
    // different RPC surface and VrseUb against library photo IDs returns
    // NOT_FOUND (status 5) in that context. Cookies persist regardless of UA,
    // so existing sign-in stays valid after the switch.
    private static let safariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // Document-START hook to intercept Google's bootstrap fetch + XHR calls.
    // GP fires the `rJ0tlb` RPC on every fresh page bootstrap — its
    // response contains the library date histogram + total count. We
    // capture it via window.fetch AND XMLHttpRequest patches, then ship
    // the raw response text up to Swift via messageHandlers (more
    // reliable than polling a window global from Swift).
    //
    // Lessons learned from prior failures:
    //   - Google batches RPCs in some calls (rpcids=foo%2CrJ0tlb%2Cbar);
    //     a literal `rpcids=rJ0tlb` substring check misses these. Use a
    //     lenient match: any `rJ0tlb` in a `batchexecute` URL.
    //   - Some Google paths use XHR, not fetch. Must patch both.
    //   - Parsing is moved to Swift — easier to debug + persist via
    //     UserDefaults, and avoids fragile JS-side histogram detection.
    private static let rJ0SnifferJS = #"""
    (function () {
      if (window.__photoCleanerRJ0SnifferInstalled) return;
      window.__photoCleanerRJ0SnifferInstalled = true;

      function postToSwift(text) {
        try {
          window.webkit.messageHandlers.rJ0tlbCapture.postMessage(text);
        } catch (e) {}
      }

      function isRJ0URL(url) {
        if (!url) return false;
        var s = String(url);
        if (s.indexOf('batchexecute') === -1) return false;
        return s.indexOf('rJ0tlb') !== -1;
      }

      // ---- Patch fetch -----------------------------------------------
      var origFetch = window.fetch;
      window.fetch = function () {
        var args = arguments;
        var url = (typeof args[0] === 'string')
          ? args[0]
          : (args[0] && args[0].url) || '';
        var p = origFetch.apply(this, args);
        if (isRJ0URL(url)) {
          p.then(function (res) {
            try { res.clone().text().then(postToSwift).catch(function () {}); }
            catch (e) {}
          }).catch(function () {});
        }
        return p;
      };

      // ---- Patch XMLHttpRequest --------------------------------------
      var Xhr = XMLHttpRequest.prototype;
      var origOpen = Xhr.open;
      var origSend = Xhr.send;
      Xhr.open = function (method, url) {
        try { this.__pcURL = url; } catch (_) {}
        return origOpen.apply(this, arguments);
      };
      Xhr.send = function () {
        try {
          if (isRJ0URL(this.__pcURL)) {
            var self = this;
            this.addEventListener('load', function () {
              try { postToSwift(self.responseText || ''); } catch (_) {}
            }, { once: true });
          }
        } catch (_) {}
        return origSend.apply(this, arguments);
      };
    })();
    """#

    // Combined harvester + trash RPC. Ported from the Chrome extension:
    //   content.js:120  deletePhotoByRpc   — XwAOJf
    //   content.js:423  getActionToken     — VrseUb
    //   content.js:353  findRpcPayload     — Google's wrb.fr response parser
    // The WIZ tokens (`at` / `bl` / `sid`) come straight off the page's
    // `window.WIZ_global_data`. No isolated-world / postMessage dance needed
    // — WKWebView JS runs in the page's main world.
    private static let userScriptJS = #"""
    (function () {
      // ---- Scroll restore after a hidden reload ------------------------------
      // After a cleanup we reload the WebView to flush GP's cached grid
      // layout (the only way to genuinely eliminate the holes left by
      // deleted tiles, since GP uses absolutely-positioned grid cells).
      //
      // Pixel-based scroll restoration doesn't work on virtualized content
      // because window.scrollTo(deepY) clamps to currently-rendered content
      // height — you can't scroll past what GP has streamed in yet.
      //
      // The robust approach is ANCHOR-based: before reload we save the ID
      // of the topmost visible photo. After reload we poll the DOM for an
      // anchor with that photo ID. While polling we scroll progressively
      // downward to force GP's virtualization to stream in more content.
      // Once the anchor element appears, scrollIntoView puts it back where
      // it was — pixel-perfect restoration regardless of layout shifts.
      try {
        var anchorId = sessionStorage.getItem('pc_anchorPhotoId');
        var savedScroll = sessionStorage.getItem('pc_savedScroll');
        sessionStorage.removeItem('pc_anchorPhotoId');
        sessionStorage.removeItem('pc_savedScroll');

        var targetScroll = savedScroll ? parseInt(savedScroll, 10) : 0;
        if (anchorId || (!isNaN(targetScroll) && targetScroll > 100)) {
          var attempts = 0;
          var maxAttempts = 60;   // ~3 seconds at the new 50ms cadence
          var found = false;
          var pinned = 0;

          // FAST PATH: immediately seek to the saved pixel depth. The
          // browser will clamp if content hasn't streamed yet, but on
          // most reloads GP serves the grid metadata fast enough that
          // the initial jump lands close. The polling loop then makes
          // up the rest in much smaller increments.
          if (targetScroll > 0) {
            try { window.scrollTo(0, targetScroll); } catch (e) {}
          }

          var tryRestore = function () {
            attempts++;
            // Strategy 1: anchor element — most reliable.
            if (anchorId) {
              var el = document.querySelector('a[href*="/photo/' + anchorId + '"]');
              if (el) {
                if (!found) {
                  found = true;
                  el.scrollIntoView({ behavior: 'instant', block: 'start' });
                }
                // Re-pin a few times because GP shifts layout as the
                // virtualizer streams in rows above/below. Two re-pins
                // is enough — more just causes scroll jitter.
                pinned++;
                if (pinned < 3) {
                  el.scrollIntoView({ behavior: 'instant', block: 'start' });
                  setTimeout(tryRestore, 120);
                }
                return;
              }
            }
            // Strategy 2: progressive scroll to force virtualization.
            // Bigger jumps (2500px) get us into the right neighborhood
            // faster on long scroll distances.
            if (targetScroll > 0) {
              var currentY = window.scrollY;
              if (currentY < targetScroll - 100) {
                window.scrollTo(0, Math.min(targetScroll, currentY + 2500));
              } else if (!found && Math.abs(currentY - targetScroll) > 50) {
                window.scrollTo(0, targetScroll);
              }
            }
            if (attempts < maxAttempts && !found) {
              setTimeout(tryRestore, 50);
            }
          };
          // Kick off immediately — the initial pixel seek above means
          // there's no need to wait for layout settle.
          setTimeout(tryRestore, 0);
        }
      } catch (e) {}

      // ---- Harvester ---------------------------------------------------------
      function extractId(href) {
        var m = /\/photo\/([^/?#]+)/.exec(href || '');
        return m ? m[1] : null;
      }
      function thumbFrom(anchor) {
        var img = anchor.querySelector('img');
        if (img) {
          if (img.src && img.src.indexOf('http') === 0) return img.src;
          var ds = img.getAttribute('data-src');
          if (ds && ds.indexOf('http') === 0) return ds;
        }
        var bg = anchor.querySelector('[style*="background-image"]');
        if (bg) {
          var s = bg.getAttribute('style') || '';
          var bm = /url\((['"]?)(https:[^'")]+)\1\)/.exec(s);
          if (bm) return bm[2];
        }
        var pic = anchor.querySelector('picture source');
        if (pic) {
          var srcset = pic.getAttribute('srcset') || '';
          var first = srcset.split(',')[0].trim().split(' ')[0];
          if (first.indexOf('http') === 0) return first;
        }
        return '';
      }
      window.__photoCleanerHarvest = function () {
        var anchors = document.querySelectorAll('a[href*="/photo/"]');
        var out = [];
        var seen = Object.create(null);
        for (var i = 0; i < anchors.length; i++) {
          var a = anchors[i];
          var id = extractId(a.getAttribute('href') || a.href);
          if (!id || seen[id]) continue;
          seen[id] = true;
          out.push({
            id: id,
            thumbUrl: thumbFrom(a),
            label: a.getAttribute('aria-label') || ''
          });
        }
        return out;
      };

      // ---- GP-native selection detection -------------------------------
      // We rely on Google Photos' own selection UI (long-press to enter
      // selection mode, tap to add/remove). We don't try to intercept clicks
      // any more — GP's tap-handling lives on different DOM nodes than the
      // photo anchor and fighting them for control just produces confusing
      // dual-state. Instead we poll the page for:
      //   1) The "N selected" header text — gives us the count GP knows about
      //   2) Photo anchors that contain a checked/selected attribute marker
      //
      // The user keeps the familiar GP selection UI; we just read it.

      // Walk up to 5 ancestors from `el`, returning the first photo anchor we
      // find. Also peeks into siblings of each ancestor because GP's grid
      // tile sometimes has the checkbox indicator as a sibling of the anchor
      // rather than an ancestor. Ported verbatim from the Chrome extension's
      // walkUpToPhotoAnchor (content.js:2295).
      function walkUpToPhotoAnchor(el) {
        var cur = el;
        for (var depth = 0; depth < 5 && cur; depth += 1) {
          if (cur.tagName === 'A' && cur.href && /\/photo\//.test(cur.href)) return cur;
          if (cur.parentElement) {
            var sib = cur.parentElement.querySelector('a[href*="/photo/"]');
            if (sib) return sib;
          }
          cur = cur.parentElement;
        }
        return null;
      }

      // Three-strategy scan ported from the Chrome extension. This is the
      // exact code that finds selected photos in desktop GP on Chrome — we
      // just run it inside our WKWebView.
      function findSelectedAnchors() {
        var anchors = new Set();

        // Strategy 1: [role="checkbox"][aria-checked="true"] (most explicit)
        document.querySelectorAll('[role="checkbox"][aria-checked="true"]').forEach(function (el) {
          var a = walkUpToPhotoAnchor(el);
          if (a) anchors.add(a);
        });

        // Strategy 2: anchors with aria-checked="true" directly
        document.querySelectorAll('a[aria-checked="true"][href*="/photo/"]').forEach(function (a) {
          anchors.add(a);
        });

        // Strategy 3: aria-selected="true" on grid cells (walk up)
        document.querySelectorAll('[aria-selected="true"]').forEach(function (el) {
          var a = walkUpToPhotoAnchor(el);
          if (a) anchors.add(a);
        });

        return Array.from(anchors);
      }

      function readGPSelectionCount() {
        // Look for the "N selected" / "N selected" text in GP's selection
        // toolbar. Restricted to short text nodes so we don't match random
        // copy.
        try {
          var walker = document.createTreeWalker(
            document.body || document.documentElement,
            NodeFilter.SHOW_TEXT,
            null,
            false
          );
          var node;
          while ((node = walker.nextNode())) {
            var text = (node.nodeValue || '').trim();
            if (!text || text.length > 30) continue;
            var m = /^(\d+)\s+selected$/i.exec(text);
            if (m) return parseInt(m[1], 10);
          }
        } catch (_) {}
        return 0;
      }

      window.__photoCleanerGPSelectedCount = function () {
        // Trust whichever signal gives us the higher count — GP's header
        // text is the most reliable, but if we can directly find the
        // selected anchors that's our actual usable set.
        var headerCount = readGPSelectionCount();
        var foundAnchors = findSelectedAnchors().length;
        return Math.max(headerCount, foundAnchors);
      };

      window.__photoCleanerGPGetSelected = function () {
        var anchors = findSelectedAnchors();
        return anchors.map(function (a) {
          var id = extractId(a.getAttribute('href') || a.href);
          return {
            id: id,
            thumbUrl: thumbFrom(a),
            label: a.getAttribute('aria-label') || ''
          };
        });
      };

      // Find the element GP actually scrolls inside. GP has rotated through
      // several layouts: sometimes window scrolling, sometimes an inner
      // [role="main"] container, sometimes a deeper jsname div. We probe
      // ALL candidates (including window), do a test-scroll on each, and
      // pick whichever actually changes the photo-anchor set. This is the
      // only reliable way — checking overflow style alone gives false
      // positives.
      window.__photoCleanerScrollerCache = window.__photoCleanerScrollerCache || null;

      async function findGPScrollContainer() {
        // Cached from previous successful test so we don't re-probe
        // every single harvest call.
        if (window.__photoCleanerScrollerCache &&
            document.contains(window.__photoCleanerScrollerCache)) {
          return window.__photoCleanerScrollerCache;
        }

        // Collect plausible scrollers including window (null sentinel).
        var candidates = [null];  // null === window
        var nodeList = document.querySelectorAll(
          '[role="main"], main, [jsname], div[style*="overflow"]'
        );
        for (var i = 0; i < nodeList.length; i++) {
          var el = nodeList[i];
          if (!el) continue;
          if (el.scrollHeight - el.clientHeight > 200) {
            candidates.push(el);
          }
        }

        // Snapshot current "fingerprint" (first 5 anchor IDs visible) so
        // we can detect which scroller actually changes the viewport.
        function fingerprint() {
          var anchors = document.querySelectorAll('a[href*="/photo/"]');
          var ids = [];
          for (var j = 0; j < anchors.length && ids.length < 5; j++) {
            var rect = anchors[j].getBoundingClientRect();
            if (rect.top > -200 && rect.top < window.innerHeight + 200) {
              var m = /\/photo\/([^/?#]+)/.exec(anchors[j].href);
              if (m) ids.push(m[1]);
            }
          }
          return ids.join('|');
        }

        var before = fingerprint();
        for (var c = 0; c < candidates.length; c++) {
          var scroller = candidates[c];
          var origY = scroller ? scroller.scrollTop : window.scrollY;
          var maxY = scroller
            ? (scroller.scrollHeight - scroller.clientHeight)
            : Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
          if (maxY < 200) continue;
          // Jump down by 1000px and see if the viewport actually changed.
          var testY = Math.min(origY + 1000, maxY);
          if (scroller) scroller.scrollTop = testY;
          else window.scrollTo(0, testY);
          await new Promise(function (r) { setTimeout(r, 150); });
          var after = fingerprint();
          // Restore.
          if (scroller) scroller.scrollTop = origY;
          else window.scrollTo(0, origY);
          if (after && after !== before) {
            window.__photoCleanerScrollerCache = scroller;
            return scroller;
          }
        }
        // Fall back to window if nothing identifiably works.
        window.__photoCleanerScrollerCache = null;
        return null;
      }

      function scrollerY(scroller) {
        return scroller ? scroller.scrollTop : window.scrollY;
      }
      function scrollerH(scroller) {
        return scroller ? scroller.clientHeight : window.innerHeight;
      }
      function scrollerMax(scroller) {
        if (scroller) return scroller.scrollHeight - scroller.clientHeight;
        return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      }
      function scrollerTo(scroller, y) {
        if (scroller) scroller.scrollTop = y;
        else window.scrollTo(0, y);
      }

      // Deep scan: drive the scrollable region top-to-bottom, accumulating
      // selected photos as GP virtualizes more rows in. Restores the
      // original scroll position when done so the user lands back where
      // they were.
      window.__photoCleanerGPGetSelectedDeep = async function () {
        var scroller = await findGPScrollContainer();
        var originalY = scrollerY(scroller);
        var headerCount = readGPSelectionCount();
        var collected = Object.create(null);

        function collectVisible() {
          var anchors = findSelectedAnchors();
          for (var i = 0; i < anchors.length; i++) {
            var a = anchors[i];
            var id = extractId(a.getAttribute('href') || a.href);
            if (id && !collected[id]) {
              collected[id] = {
                id: id,
                thumbUrl: thumbFrom(a),
                label: a.getAttribute('aria-label') || ''
              };
            }
          }
        }

        // First pass: what's already visible.
        collectVisible();
        function count() { return Object.keys(collected).length; }
        if (headerCount > 0 && count() >= headerCount) {
          return Object.keys(collected).map(function (k) { return collected[k]; });
        }

        // Jump to top, then walk down in viewport-sized steps. GP renders a
        // row's worth on each scroll, so each pause needs to be long enough
        // for the virtualizer to commit DOM.
        scrollerTo(scroller, 0);
        await new Promise(function (r) { setTimeout(r, 250); });
        collectVisible();

        var safety = 200;
        var lastY = -1;
        while (safety-- > 0) {
          if (headerCount > 0 && count() >= headerCount) break;
          var beforeY = scrollerY(scroller);
          var step = Math.max(scrollerH(scroller) * 0.75, 400);
          scrollerTo(scroller, beforeY + step);
          await new Promise(function (r) { setTimeout(r, 180); });
          collectVisible();
          var afterY = scrollerY(scroller);
          if (afterY === beforeY || afterY === lastY) {
            // Either at bottom or stuck — give it one more chance to load,
            // then break.
            await new Promise(function (r) { setTimeout(r, 250); });
            collectVisible();
            if (scrollerY(scroller) === afterY) break;
          }
          lastY = afterY;
        }

        // Final sweep at the bottom.
        collectVisible();

        // Restore.
        scrollerTo(scroller, originalY);

        var out = [];
        for (var k in collected) out.push(collected[k]);
        return out;
      };

      // Diagnostic: returns details about the selection state so we can
      // refine our DOM scans if GP rotates their markup.
      window.__photoCleanerGPSelectionDebug = function () {
        var headerCount = readGPSelectionCount();
        var foundAnchors = findSelectedAnchors();
        var ariaCheckedAll = document.querySelectorAll('[aria-checked="true"]');
        var ariaSelectedAll = document.querySelectorAll('[aria-selected="true"]');
        var roleCheckboxAll = document.querySelectorAll('[role="checkbox"]');
        var roleCheckboxChecked = document.querySelectorAll('[role="checkbox"][aria-checked="true"]');
        var dataCheckedAll = document.querySelectorAll('[data-checked="true"]');
        var inputCheckedAll = document.querySelectorAll('input[type="checkbox"]:checked');

        // First aria-checked element's HTML so we can see what GP actually uses.
        var sampleChecked = ariaCheckedAll.length > 0
          ? ariaCheckedAll[0].outerHTML.substring(0, 400)
          : null;
        var sampleSelected = ariaSelectedAll.length > 0
          ? ariaSelectedAll[0].outerHTML.substring(0, 400)
          : null;
        var sampleRoleCheckbox = roleCheckboxAll.length > 0
          ? roleCheckboxAll[0].outerHTML.substring(0, 400)
          : null;

        return {
          headerCount: headerCount,
          anchorsFoundWithMarker: foundAnchors.length,
          totalPhotoAnchors: document.querySelectorAll('a[href*="/photo/"]').length,
          countAriaCheckedTrue: ariaCheckedAll.length,
          countAriaSelectedTrue: ariaSelectedAll.length,
          countRoleCheckbox: roleCheckboxAll.length,
          countRoleCheckboxChecked: roleCheckboxChecked.length,
          countDataCheckedTrue: dataCheckedAll.length,
          countInputChecked: inputCheckedAll.length,
          sampleAriaChecked: sampleChecked,
          sampleAriaSelected: sampleSelected,
          sampleRoleCheckbox: sampleRoleCheckbox
        };
      };

      // ---- Trash RPC --------------------------------------------------------
      // Throws a descriptive error if WIZ isn't ready or the expected field
      // names have rotated — so the cleanup summary can show us what's missing.
      function getWiz() {
        var w = window.WIZ_global_data;
        if (!w || typeof w !== 'object') {
          throw new Error('window.WIZ_global_data missing (page may be the mobile lite version)');
        }
        var at = w['SNlM0e'];
        if (!at) {
          var keys = Object.keys(w).slice(0, 30).join(',');
          throw new Error('WIZ has no SNlM0e (at token). Keys present: ' + keys);
        }
        return {
          at: at,
          bl: w['cfb2h'] || null,
          sid: w['FdrFJe'] || null
        };
      }

      function findRpcPayloadInText(text, rpcid) {
        var marker = '"wrb.fr","' + rpcid + '","';
        var searchStart = 0;
        while (searchStart < text.length) {
          var start = text.indexOf(marker, searchStart);
          if (start === -1) return null;
          var pos = start + marker.length;
          var escaped = '';
          var found = false;
          while (pos < text.length) {
            var ch = text[pos];
            if (ch === '\\') {
              escaped += ch + (text[pos + 1] || '');
              pos += 2;
              continue;
            }
            if (ch === '"') { found = true; break; }
            escaped += ch;
            pos += 1;
          }
          if (!found) return null;
          try {
            var inner = JSON.parse('"' + escaped + '"');
            return JSON.parse(inner);
          } catch (e) {
            searchStart = start + marker.length;
            continue;
          }
        }
        return null;
      }

      function commonParams(url, wiz, photoIdForSourcePath, soc_device) {
        if (wiz.sid) url.searchParams.set('f.sid', wiz.sid);
        if (wiz.bl)  url.searchParams.set('bl', wiz.bl);
        url.searchParams.set('hl', 'en');
        url.searchParams.set('soc-app', '165');
        url.searchParams.set('soc-platform', '1');
        url.searchParams.set('soc-device', soc_device || '4');
        url.searchParams.set('_reqid', String(Date.now() % 10000000));
        url.searchParams.set('rt', 'c');
        url.searchParams.set('source-path', '/photo/' + photoIdForSourcePath);
      }

      async function getActionToken(libraryId) {
        var wiz = getWiz();
        if (!wiz.at) throw new Error('WIZ not ready');

        var url = new URL('https://photos.google.com/_/PhotosUi/data/batchexecute');
        url.searchParams.set('rpcids', 'VrseUb');
        commonParams(url, wiz, libraryId, '4');

        var inner = JSON.stringify([libraryId, '', null, null, null, null, null, 1]);
        var body = new URLSearchParams();
        body.set('f.req', JSON.stringify([[['VrseUb', inner, null, '1']]]));
        body.set('at', wiz.at);

        var res = await fetch(url.toString(), {
          method: 'POST',
          credentials: 'include',
          referrer: 'https://photos.google.com/photo/' + libraryId,
          headers: {
            'content-type': 'application/x-www-form-urlencoded;charset=UTF-8',
            'x-same-domain': '1'
          },
          body: body.toString()
        });
        if (!res.ok) throw new Error('VrseUb HTTP ' + res.status + ' [id=' + libraryId + ']');
        var text = await res.text();
        var payload = findRpcPayloadInText(text, 'VrseUb');
        if (!payload) {
          var preview = (text || '').substring(0, 280).replace(/\s+/g, ' ');
          throw new Error(
            'VrseUb no payload [id=' + libraryId + ' len=' + libraryId.length +
            ' page=' + location.pathname + ']: ' + preview
          );
        }
        var token = payload[3] || null;
        if (!token) {
          throw new Error('VrseUb no actionToken at [3] [id=' + libraryId + ']. Payload: ' + JSON.stringify(payload).substring(0, 240));
        }
        return token;
      }

      async function deletePhotoByRpc(photoId, actionToken) {
        var wiz = getWiz();
        if (!wiz.at) throw new Error('WIZ not ready');

        var url = new URL('https://photos.google.com/_/PhotosUi/data/batchexecute');
        url.searchParams.set('rpcids', 'XwAOJf');
        commonParams(url, wiz, photoId, '4');

        var inner = JSON.stringify([null, 1, [actionToken], 3]);
        var body = new URLSearchParams();
        body.set('f.req', JSON.stringify([[['XwAOJf', inner, null, 'generic']]]));
        body.set('at', wiz.at);

        var photoUrl = 'https://photos.google.com/photo/' + photoId;
        var res = await fetch(url.toString(), {
          method: 'POST',
          credentials: 'include',
          referrer: photoUrl,
          referrerPolicy: 'strict-origin-when-cross-origin',
          headers: {
            'content-type': 'application/x-www-form-urlencoded;charset=UTF-8',
            'x-same-domain': '1'
          },
          body: body.toString()
        });
        if (!res.ok) throw new Error('XwAOJf HTTP ' + res.status);
        var text = await res.text();
        if (text.indexOf('"wrb.er"') !== -1) {
          var preview = (text || '').substring(0, 240).replace(/\s+/g, ' ');
          throw new Error('XwAOJf: Google returned error frame. Preview: ' + preview);
        }
        var payload = findRpcPayloadInText(text, 'XwAOJf');
        if (!payload) {
          var preview = (text || '').substring(0, 240).replace(/\s+/g, ' ');
          throw new Error('XwAOJf: no payload. Preview: ' + preview);
        }
        var echoed = payload && Array.isArray(payload) && Array.isArray(payload[0]) && payload[0][0];
        if (echoed !== photoId) {
          throw new Error('XwAOJf no echo. Sent: ' + photoId + ' Got: ' + JSON.stringify(payload).substring(0, 240));
        }
        return true;
      }

      // ---- EzkLib date search (primary path) -------------------------------
      // Single RPC per date returns every photo on that date with id + url +
      // createTime + actionToken in one shot. We then match our harvested
      // photoIds against the result list and reuse the actionTokens straight
      // into XwAOJf. This replaces VrseUb as the source of actionTokens
      // because VrseUb requires session state (selection / pre-load) that
      // a fresh WebView load doesn't have — it returns NOT_FOUND for cold
      // library IDs.
      async function searchPhotosByDate(dateString) {
        var wiz = getWiz();
        var url = new URL('https://photos.google.com/_/PhotosUi/data/batchexecute');
        url.searchParams.set('rpcids', 'EzkLib');
        url.searchParams.set('source-path', '/');
        if (wiz.sid) url.searchParams.set('f.sid', wiz.sid);
        if (wiz.bl)  url.searchParams.set('bl', wiz.bl);
        url.searchParams.set('hl', 'en');
        url.searchParams.set('soc-app', '165');
        url.searchParams.set('soc-platform', '1');
        // EzkLib in the Chrome extension uses soc-device=1 (the search RPC's
        // own value); VrseUb used 4. Keep them per-RPC, not per-page.
        url.searchParams.set('soc-device', '1');
        url.searchParams.set('_reqid', String(Date.now() % 10000000));
        url.searchParams.set('rt', 'c');

        // Captured body: [null,null,null,null,100,null,2,[date],null,[1,1]]
        var inner = JSON.stringify([null, null, null, null, 100, null, 2, [dateString], null, [1, 1]]);
        var body = new URLSearchParams();
        body.set('f.req', JSON.stringify([[['EzkLib', inner, null, 'generic']]]));
        body.set('at', wiz.at);

        var res = await fetch(url.toString(), {
          method: 'POST',
          credentials: 'include',
          headers: {
            'content-type': 'application/x-www-form-urlencoded;charset=UTF-8',
            'x-same-domain': '1'
          },
          body: body.toString()
        });
        if (!res.ok) throw new Error('EzkLib HTTP ' + res.status + ' [date=' + dateString + ']');
        var text = await res.text();
        var payload = findRpcPayloadInText(text, 'EzkLib');
        if (!payload) {
          var preview = (text || '').substring(0, 280).replace(/\s+/g, ' ');
          throw new Error('EzkLib no payload [date=' + dateString + ']: ' + preview);
        }
        if (!Array.isArray(payload[0])) return [];
        // Each entry: [id, [url,w,h,...], createTime, actionToken, tzOffsetMs, modifiedTime, ...]
        // STRICT video detection — only when entry[1][3] is a plausible
        // duration in milliseconds (500ms .. 24h). The lenient version
        // that also did deep-scans for any duration-shaped number was
        // matching on photo metadata (file sizes, total pixel counts,
        // etc.) and falsely classifying photos as videos.
        //
        // Cost of being strict: some videos with non-standard entry
        // shapes show up as photos (no autoplay; the GP-baked play
        // overlay on the thumbnail still indicates they're videos
        // visually). That's acceptable — vastly better than labeling
        // every photo as "Video" in the triage card.
        function isVid(entry) {
          if (!Array.isArray(entry) || !Array.isArray(entry[1])) return false;
          if (entry[1].length < 4) return false;
          var dur = entry[1][3];
          if (typeof dur !== 'number') return false;
          if (dur < 500 || dur > 86400000) return false;
          return true;
        }
        // Find a byte-sized number (10KB..1GB) elsewhere in the entry
        // — that's the file size. EzkLib's exact position rotates by
        // photo source; scan defensively. Skip ms timestamps (>=1e12)
        // and small dimension numbers (<10000).
        function findSize(entry) {
          function scan(node, depth) {
            if (depth > 4) return 0;
            if (typeof node === 'number') {
              if (node >= 10_000 && node <= 1_073_741_824 /* 1GB */) return node;
              return 0;
            }
            if (Array.isArray(node)) {
              for (var i = 0; i < node.length; i++) {
                var v = scan(node[i], depth + 1);
                if (v) return v;
              }
            }
            return 0;
          }
          // Don't look inside entry[1] — that's [url, w, h, duration] and
          // pixel counts can fall in the byte range. Start at entry[6]+.
          for (var i = 6; i < entry.length; i++) {
            var s = scan(entry[i], 0);
            if (s) return s;
          }
          return 0;
        }

        return payload[0].map(function (entry) {
          var url = (Array.isArray(entry[1]) && typeof entry[1][0] === 'string')
            ? entry[1][0] : '';
          return {
            id: entry[0],
            thumbUrl: url,
            actionToken: entry[3] || null,
            createTime: entry[2] || null,
            isVideo: isVid(entry),
            sizeBytes: findSize(entry)
          };
        });
      }

      // Per-page-load cache so multiple deletes for photos on the same date
      // share a single EzkLib call.
      window.__photoCleanerDateCache = window.__photoCleanerDateCache || {};

      async function searchByDateCached(dateString) {
        if (window.__photoCleanerDateCache[dateString]) {
          return window.__photoCleanerDateCache[dateString];
        }
        var photos = await searchPhotosByDate(dateString);
        window.__photoCleanerDateCache[dateString] = photos;
        return photos;
      }

      // Fire-and-forget: pre-warm the EzkLib cache for a set of dates in
      // parallel. Called from Swift as soon as triage starts so action tokens
      // are already in memory by the time the user taps Delete — the bulk
      // RPC then has zero setup cost.
      window.__photoCleanerPrefetchDates = async function (dates) {
        if (!Array.isArray(dates)) return 0;
        await Promise.all(dates.map(function (d) {
          return searchByDateCached(d).catch(function () { return []; });
        }));
        return dates.length;
      };

      window.__photoCleanerDelete = async function (photoId, dateString) {
        if (!photoId) throw new Error('Empty photoId');
        if (!dateString) throw new Error('Empty dateString (needed for EzkLib search)');

        var photos;
        try {
          photos = await searchByDateCached(dateString);
        } catch (e) {
          throw new Error('EzkLib step: ' + (e && e.message ? e.message : String(e)));
        }

        var match = null;
        for (var i = 0; i < photos.length; i++) {
          if (photos[i].id === photoId) { match = photos[i]; break; }
        }
        if (!match) {
          throw new Error(
            'EzkLib: photo ' + photoId + ' not in "' + dateString +
            '" results (' + photos.length + ' photos found on that date)'
          );
        }
        if (!match.actionToken) {
          throw new Error('EzkLib: photo ' + photoId + ' found but no actionToken');
        }

        // Time the XwAOJf round-trip so the summary can show min/avg/max
        // per call. Tells us if the slowness is per-RPC server time vs
        // some Swift-side overhead.
        var t0 = Date.now();
        try {
          var result = await deletePhotoByRpc(photoId, match.actionToken);
          var elapsed = Date.now() - t0;
          var p = window.__photoCleanerBulkProgress;
          if (p) {
            p.callCount = (p.callCount || 0) + 1;
            p.totalCallMs = (p.totalCallMs || 0) + elapsed;
            if (!p.maxCallMs || elapsed > p.maxCallMs) p.maxCallMs = elapsed;
            if (!p.minCallMs || elapsed < p.minCallMs) p.minCallMs = elapsed;
          }
          return result;
        } catch (e) {
          throw new Error('XwAOJf step: ' + (e && e.message ? e.message : String(e)));
        }
      };

      // Result-as-data wrapper so Swift can read the JS error reliably.
      window.__photoCleanerDeleteSafe = async function (photoId, dateString) {
        try {
          await window.__photoCleanerDelete(photoId, dateString);
          return { ok: true };
        } catch (e) {
          return { ok: false, error: (e && e.message) ? e.message : String(e) };
        }
      };

      // ---- Multi-token XwAOJf bulk delete --------------------------------
      // The real trick: a single XwAOJf inner RPC takes a VARIADIC token
      // array, not just one token. Google's own bulk-delete UI uses this
      // shape — up to ~100 tokens per call. ONE HTTP round-trip trashes
      // the whole batch.
      //
      // Body:   [null, 1, [tok1, tok2, ..., tok100], 3]
      // Response: [[id1, id2, ..., id100]]  — successfully-trashed IDs
      //
      // Defensive halving: if Google rejects a chunk, split in half and
      // recurse; partial-echo (some IDs missing) → per-item retry.
      window.__photoCleanerBulkProgress = {
        done: 0, total: 0, failed: 0, lastError: '',
        phase: 'idle', startMs: 0, durationMs: 0,
        callCount: 0, totalCallMs: 0, minCallMs: 0, maxCallMs: 0
      };

      async function deletePhotosBulkMultiToken(actionTokens) {
        if (!actionTokens || actionTokens.length === 0) return [];
        var wiz = getWiz();

        var url = new URL('https://photos.google.com/_/PhotosUi/data/batchexecute');
        url.searchParams.set('rpcids', 'XwAOJf');
        url.searchParams.set('source-path', '/');
        if (wiz.sid) url.searchParams.set('f.sid', wiz.sid);
        if (wiz.bl)  url.searchParams.set('bl', wiz.bl);
        url.searchParams.set('hl', 'en');
        url.searchParams.set('soc-app', '165');
        url.searchParams.set('soc-platform', '1');
        url.searchParams.set('soc-device', '4');
        url.searchParams.set('_reqid', String(Date.now() % 10000000));
        url.searchParams.set('rt', 'c');

        // KEY: tokens go inside the SAME inner RPC array, not split across
        // multiple inner RPCs.
        var inner = JSON.stringify([null, 1, actionTokens, 3]);
        var body = new URLSearchParams();
        body.set('f.req', JSON.stringify([[['XwAOJf', inner, null, 'generic']]]));
        body.set('at', wiz.at);

        var res = await fetch(url.toString(), {
          method: 'POST',
          credentials: 'include',
          referrer: 'https://photos.google.com/',
          referrerPolicy: 'strict-origin-when-cross-origin',
          headers: {
            'content-type': 'application/x-www-form-urlencoded;charset=UTF-8',
            'x-same-domain': '1'
          },
          body: body.toString()
        });
        if (!res.ok) throw new Error('bulk XwAOJf HTTP ' + res.status);
        var text = await res.text();
        if (text.indexOf('"wrb.er"') !== -1) {
          var preview = text.substring(0, 280).replace(/\s+/g, ' ');
          throw new Error('bulk XwAOJf error frame: ' + preview);
        }
        var payload = findRpcPayloadInText(text, 'XwAOJf');
        if (!payload) {
          var preview = text.substring(0, 280).replace(/\s+/g, ' ');
          throw new Error('bulk XwAOJf no payload: ' + preview);
        }
        // Shape: [[id1, id2, ...]]
        var deletedIds = (Array.isArray(payload) && Array.isArray(payload[0])) ? payload[0] : [];
        return deletedIds;
      }

      // Try a chunk; on failure halve and recurse, on partial echo retry
      // the missing items per-item. Returns the array of trashed IDs.
      async function deleteChunkWithHalving(chunk) {
        if (chunk.length === 0) return [];

        var t0 = Date.now();
        try {
          var tokens = chunk.map(function (c) { return c.token; });
          var echoed = await deletePhotosBulkMultiToken(tokens);

          var elapsed = Date.now() - t0;
          var p = window.__photoCleanerBulkProgress;
          if (p) {
            p.callCount = (p.callCount || 0) + 1;
            p.totalCallMs = (p.totalCallMs || 0) + elapsed;
            if (!p.maxCallMs || elapsed > p.maxCallMs) p.maxCallMs = elapsed;
            if (!p.minCallMs || elapsed < p.minCallMs) p.minCallMs = elapsed;
          }

          if (echoed.length === chunk.length) return echoed;

          // Partial echo — figure out which ones Google didn't acknowledge
          // and retry them individually.
          var echoedSet = Object.create(null);
          for (var i = 0; i < echoed.length; i++) echoedSet[echoed[i]] = true;
          var missing = chunk.filter(function (c) { return !echoedSet[c.id]; });

          var combined = echoed.slice();
          for (var m = 0; m < missing.length; m++) {
            try {
              var single = await deletePhotosBulkMultiToken([missing[m].token]);
              for (var s = 0; s < single.length; s++) combined.push(single[s]);
            } catch (e) {
              // give up on this single
            }
          }
          return combined;
        } catch (e) {
          // Full rejection. Halve and recurse — eventually we hit single
          // tokens and either succeed individually or drop them.
          if (chunk.length === 1) return [];
          var mid = Math.floor(chunk.length / 2);
          var left = await deleteChunkWithHalving(chunk.slice(0, mid));
          var right = await deleteChunkWithHalving(chunk.slice(mid));
          return left.concat(right);
        }
      }

      window.__photoCleanerBulkDelete = async function (photos, concurrency) {
        var total = (photos || []).length;
        window.__photoCleanerBulkProgress = {
          done: 0, total: total, failed: 0, lastError: '',
          phase: 'init', startMs: Date.now(), durationMs: 0,
          callCount: 0, totalCallMs: 0, minCallMs: 0, maxCallMs: 0
        };
        if (total === 0) return { ok: 0, failedIds: [] };

        // ---- Phase 1: pre-fetch every unique date's EzkLib in parallel ----
        window.__photoCleanerBulkProgress.phase = 'prefetch';
        var dateSet = Object.create(null);
        for (var i = 0; i < photos.length; i++) {
          if (photos[i].dateString) dateSet[photos[i].dateString] = true;
        }
        var dates = Object.keys(dateSet);
        await Promise.all(dates.map(function (d) {
          return searchByDateCached(d).catch(function (e) {
            window.__photoCleanerBulkProgress.lastError =
              'EzkLib prefetch failed for ' + d + ': ' + ((e && e.message) || String(e));
            return [];
          });
        }));

        // Build id -> actionToken map from cache.
        var tokenMap = Object.create(null);
        for (var d = 0; d < dates.length; d++) {
          var results = window.__photoCleanerDateCache[dates[d]] || [];
          for (var r = 0; r < results.length; r++) {
            if (results[r].actionToken) tokenMap[results[r].id] = results[r].actionToken;
          }
        }

        var bulkOrder = [];
        var fallback = [];
        for (var p = 0; p < photos.length; p++) {
          var ph = photos[p];
          var t = tokenMap[ph.id];
          if (t) bulkOrder.push({ id: ph.id, token: t, dateString: ph.dateString });
          else fallback.push(ph);
        }

        // ---- Phase 2: multi-token bulk delete in chunks of 100 ----
        var allEchoed = Object.create(null);
        var CHUNK_SIZE = 100;

        if (bulkOrder.length > 0) {
          window.__photoCleanerBulkProgress.phase = 'bulk';
          for (var c = 0; c < bulkOrder.length; c += CHUNK_SIZE) {
            var chunk = bulkOrder.slice(c, c + CHUNK_SIZE);
            var echoedIds = await deleteChunkWithHalving(chunk);
            for (var e = 0; e < echoedIds.length; e++) {
              if (!allEchoed[echoedIds[e]]) {
                allEchoed[echoedIds[e]] = true;
                window.__photoCleanerBulkProgress.done++;
              }
            }
          }
        }

        // ---- Phase 3: per-photo fallback for anything left over ----
        // Mostly photos that had no actionToken (date wasn't in EzkLib
        // cache). Rare in practice.
        var stillToDo = [];
        for (var b = 0; b < bulkOrder.length; b++) {
          if (!allEchoed[bulkOrder[b].id]) {
            stillToDo.push({ id: bulkOrder[b].id, dateString: bulkOrder[b].dateString });
          }
        }
        for (var fi = 0; fi < fallback.length; fi++) {
          stillToDo.push({ id: fallback[fi].id, dateString: fallback[fi].dateString });
        }

        if (stillToDo.length > 0) {
          window.__photoCleanerBulkProgress.phase = 'parallel';
          var nextIdx = 0;
          async function worker() {
            while (true) {
              var myIdx = nextIdx++;
              if (myIdx >= stillToDo.length) return;
              var item = stillToDo[myIdx];
              try {
                await window.__photoCleanerDelete(item.id, item.dateString);
                allEchoed[item.id] = true;
                window.__photoCleanerBulkProgress.done++;
              } catch (e) {
                var msg = (e && e.message) ? e.message : String(e);
                window.__photoCleanerBulkProgress.failed++;
                window.__photoCleanerBulkProgress.lastError = msg;
              }
            }
          }
          var n = Math.min(concurrency || 4, stillToDo.length);
          var workers = [];
          for (var w = 0; w < n; w++) workers.push(worker());
          await Promise.all(workers);
        }

        window.__photoCleanerBulkProgress.phase = 'done';
        window.__photoCleanerBulkProgress.durationMs =
          Date.now() - window.__photoCleanerBulkProgress.startMs;

        var okCount = 0;
        var failedIds = [];
        for (var i2 = 0; i2 < photos.length; i2++) {
          if (allEchoed[photos[i2].id]) okCount++;
          else failedIds.push(photos[i2].id);
        }
        return { ok: okCount, failedIds: failedIds };
      };

      window.__photoCleanerGetBulkProgress = function () {
        return window.__photoCleanerBulkProgress || {
          done: 0, total: 0, failed: 0, lastError: '',
          phase: 'idle', startMs: 0, durationMs: 0,
          callCount: 0, totalCallMs: 0, minCallMs: 0, maxCallMs: 0
        };
      };

      // ---- Visual cleanup -----------------------------------------------
      // hideDeleted: animate the deleted tiles popping out and detach them
      // from the DOM. Intentionally does NOT reload — the previous version
      // did, but the reload was firing while the bulk delete RPC was still
      // in flight, killing the fetch mid-request and failing every photo.
      //
      // The reload is now a separate call (__photoCleanerReloadKeepingScroll)
      // which Swift fires only AFTER the bulk RPC has actually completed.
      window.__photoCleanerHideDeleted = function (photoIds) {
        if (!Array.isArray(photoIds) || photoIds.length === 0) return 0;
        var idSet = Object.create(null);
        for (var i = 0; i < photoIds.length; i++) idSet[photoIds[i]] = true;

        var tiles = [];
        document.querySelectorAll('a[href*="/photo/"]').forEach(function (a) {
          var m = /\/photo\/([^/?#]+)/.exec(a.getAttribute('href') || a.href);
          if (!m || !idSet[m[1]]) return;
          var tile = a.closest('[role="gridcell"]') ||
                     a.closest('[jsname]') ||
                     a.parentElement || a;
          tiles.push(tile);
        });

        if (tiles.length === 0) return 0;

        // Pop-out animation for visual feedback.
        tiles.forEach(function (tile) {
          tile.style.transition = 'transform 0.18s ease-out, opacity 0.18s ease-out';
          tile.style.transform = 'scale(0)';
          tile.style.opacity = '0';
          tile.style.pointerEvents = 'none';
        });

        // Detach after the animation completes so siblings have a chance
        // (if the grid is auto-flow) to reflow.
        setTimeout(function () {
          tiles.forEach(function (tile) {
            if (tile.parentNode) tile.parentNode.removeChild(tile);
          });
        }, 200);

        return tiles.length;
      };

      // ---- Native GP-UI delete ------------------------------------------
      // Instead of calling the trash RPC ourselves, drive GP's own delete
      // workflow: deselect the "keep" photos, click the trash button in
      // the selection toolbar, then confirm. GP's own UI handles the
      // delete + grid refresh natively — no reload, no scroll loss, no
      // gaps. Falls back to XwAOJf if the selectors aren't found.

      function fullClick(el) {
        if (!el) return;
        try {
          var rect = el.getBoundingClientRect();
          var x = rect.left + rect.width / 2;
          var y = rect.top + rect.height / 2;
          // Fire the full pointer + mouse + click sequence so listeners
          // attached via addEventListener (not just onclick) get the event.
          ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (type) {
            try {
              var ev;
              if (type.indexOf('pointer') === 0) {
                ev = new PointerEvent(type, {
                  clientX: x, clientY: y, bubbles: true, cancelable: true,
                  pointerType: 'touch', isPrimary: true
                });
              } else {
                ev = new MouseEvent(type, {
                  clientX: x, clientY: y, bubbles: true, cancelable: true
                });
              }
              el.dispatchEvent(ev);
            } catch (e) {}
          });
          // Last-resort native click.
          try { el.click(); } catch (e) {}
        } catch (e) {}
      }

      // Walk up from the "N selected" header to the toolbar container that
      // owns it. That toolbar holds the trash/share/info action buttons —
      // scoping our trash-button search to this container is what keeps us
      // from accidentally matching the sidebar's "Trash" navigation entry
      // (which would navigate to /trash/ and lose the user's place).
      function findGPSelectionToolbar() {
        try {
          var walker = document.createTreeWalker(
            document.body || document.documentElement,
            NodeFilter.SHOW_TEXT, null, false
          );
          var node;
          while ((node = walker.nextNode())) {
            var text = (node.nodeValue || '').trim();
            if (!text || text.length > 30) continue;
            if (!/^\d+\s+selected$/i.test(text)) continue;
            // Walk up a few levels to find a container that holds buttons.
            var p = node.parentElement;
            for (var i = 0; i < 8 && p; i++) {
              var btns = p.querySelectorAll('[role="button"], button');
              if (btns.length >= 2) return p;
              p = p.parentElement;
            }
          }
        } catch (_) {}
        return null;
      }

      function findGPTrashButton() {
        // PRIMARY: scoped search inside the selection toolbar. This is the
        // critical fix — the GP sidebar has a "Trash" nav entry that
        // matches our /^trash$/ regex; clicking it navigated the WebView
        // to /trash/ and lost the user's scroll position. Scoping to the
        // toolbar means we only match the actual selection action button.
        var toolbar = findGPSelectionToolbar();
        var nav = document.querySelector('[role="navigation"], nav');

        function isNavButton(el) {
          if (!el) return false;
          if (nav && nav.contains(el)) return true;
          // GP's sidebar nav entries are <a href="/trash"> — exclude any
          // anchor with /trash or /albums in its href.
          var a = el.closest('a[href]');
          if (a && /\/(trash|albums|search|sharing|favorites|archive)/i.test(a.getAttribute('href') || '')) return true;
          return false;
        }

        function scanIn(root) {
          var all = root.querySelectorAll('[role="button"], button, [jsaction]');
          var best = null;
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            if (isNavButton(el)) continue;
            var label = (el.getAttribute('aria-label') || '').toLowerCase();
            var tip = (el.getAttribute('data-tooltip') || '').toLowerCase();
            var combined = label + ' ' + tip;
            // Strict exclude — anything that obviously isn't the trash action.
            if (/share|add to|create|cancel|close|info|select|menu|search|account|back|navigation|home|library|album|favorite|archive|locked folder/i.test(combined)) {
              continue;
            }
            // Affirmative trash indicators (the actual action button)
            if (/move to trash|move to bin|move to recycle|trash this|delete this|delete selected|delete photo|delete forever|delete from device|^bin$|^recycle/i.test(combined)) {
              return el;
            }
            // Last-resort match: bare "trash" or "delete" — BUT only when
            // we're inside the toolbar (not at page scope) so we don't
            // accidentally grab a nav entry.
            if (!best && root !== document && /^trash$|^delete$|trash|delete/i.test(combined)) {
              best = el;
            }
          }
          return best;
        }

        if (toolbar) {
          var inToolbar = scanIn(toolbar);
          if (inToolbar) return inToolbar;
        }
        // Fallback: page scope, but strict regex only — no bare "trash" match.
        return scanIn(document);
      }

      // Diagnostic: returns details about the visible toolbar buttons so we
      // can refine selectors when the live GP DOM doesn't match expectations.
      function describeGPButtons(limit) {
        var all = document.querySelectorAll('[role="button"], button, [jsaction]');
        var out = [];
        for (var i = 0; i < Math.min(all.length, limit || 30); i++) {
          var lbl = all[i].getAttribute('aria-label');
          var tip = all[i].getAttribute('data-tooltip');
          if (lbl || tip) out.push('label="' + (lbl || '') + '" tip="' + (tip || '') + '"');
        }
        return out;
      }

      async function clickGPTrashConfirm(maxWaitMs) {
        var start = Date.now();
        while (Date.now() - start < maxWaitMs) {
          // Look in any dialog/alertdialog that's open
          var dialogs = document.querySelectorAll('[role="dialog"], [role="alertdialog"]');
          for (var i = 0; i < dialogs.length; i++) {
            var buttons = dialogs[i].querySelectorAll('button, [role="button"]');
            // Confirm button text varies: "Move to trash", "Delete", or just affirmative
            for (var j = 0; j < buttons.length; j++) {
              var text = (buttons[j].textContent || '').trim().toLowerCase();
              var label = (buttons[j].getAttribute('aria-label') || '').toLowerCase();
              var combined = text + ' ' + label;
              // Skip Cancel-y buttons
              if (/cancel|dismiss|nope|never mind/i.test(combined)) continue;
              // Match affirmative trash actions
              if (/move to trash|move/i.test(combined) ||
                  (/trash|delete/i.test(combined) && !/restore/i.test(combined))) {
                fullClick(buttons[j]);
                return true;
              }
            }
          }
          await new Promise(function (r) { setTimeout(r, 100); });
        }
        return false;
      }

      // Find the checkmark/selection indicator for a photo. Critical: we
      // need to click the CHECKMARK, not the photo anchor — clicking the
      // anchor in GP sometimes navigates to detail view instead of toggling
      // selection. The checkmark element is the dedicated selection target.
      function findSelectionCheckmark(anchor) {
        if (!anchor) return null;
        // Search inside the anchor for an explicit checkbox role.
        var cb = anchor.querySelector('[role="checkbox"][aria-checked="true"]') ||
                 anchor.querySelector('[aria-checked="true"]') ||
                 anchor.querySelector('[aria-selected="true"]');
        if (cb) return cb;
        // GP sometimes renders the checkbox as a sibling of the anchor —
        // walk up a few levels and look for a checked element that isn't an
        // ancestor of our anchor (which would mean the whole tile, not the
        // checkbox itself).
        var p = anchor.parentElement;
        for (var i = 0; i < 4 && p; i++) {
          var cand = p.querySelector('[role="checkbox"][aria-checked="true"]') ||
                     p.querySelector('[aria-checked="true"]');
          if (cand && cand !== anchor && !cand.contains(anchor)) {
            return cand;
          }
          p = p.parentElement;
        }
        return null;
      }

      window.__photoCleanerDeleteViaGPUI = async function (keepIds, expectedCount) {
        // ---- Pre-check: is GP actually in selection mode? --------------
        // If the user reached cleanup via the Random pill (not by long-
        // pressing photos in GP first), there's no "N selected" toolbar
        // and no checkmarks in the DOM. The native UI path can't possibly
        // work — fall back to XwAOJf immediately rather than scanning a
        // page-wide button list and matching the wrong button.
        var toolbar = findGPSelectionToolbar();
        var anyChecked = document.querySelector('[aria-checked="true"], [role="checkbox"][aria-checked="true"]');
        if (!toolbar && !anyChecked) {
          return { ok: false, error: 'GP not in selection mode (photos came from Random/programmatic) — XwAOJf required' };
        }

        // 1. Deselect every photo we marked as "keep". Target the checkmark
        //    element specifically — clicking the anchor body can navigate
        //    to photo detail instead of toggling selection.
        if (Array.isArray(keepIds) && keepIds.length > 0) {
          for (var i = 0; i < keepIds.length; i++) {
            var anchor = document.querySelector('a[href*="/photo/' + keepIds[i] + '"]');
            if (!anchor) continue;
            var checkmark = findSelectionCheckmark(anchor);
            if (checkmark) {
              fullClick(checkmark);
            }
            // If no checkmark found, the photo wasn't selected — skip,
            // don't fall back to clicking the anchor (would navigate).
            await new Promise(function (r) { setTimeout(r, 100); });
          }
          // Let GP's header count settle after the last deselect click.
          await new Promise(function (r) { setTimeout(r, 250); });
        }

        // 1b. SAFETY: GP's trash will delete whatever is STILL selected.
        //     If the deep harvest under-collected (virtualized grid, scroll
        //     cap), photos the user never triaged are still selected right
        //     now — clicking trash would delete them. Verify GP's own "N
        //     selected" header equals the delete-queue size; on mismatch,
        //     abort so the XwAOJf fallback (which deletes exactly the
        //     queued IDs, nothing more) takes over.
        if (typeof expectedCount === 'number' && expectedCount > 0) {
          var remaining = readGPSelectionCount();
          if (remaining > 0 && remaining !== expectedCount) {
            return {
              ok: false,
              error: 'selection mismatch: GP shows ' + remaining +
                     ' selected but delete queue has ' + expectedCount +
                     ' — aborting native trash, using XwAOJf'
            };
          }
        }

        // 2. Click the trash button in the selection toolbar.
        var trash = findGPTrashButton();
        if (!trash) {
          // Diagnostic: dump every aria-label / data-tooltip we can find so
          // we can refine the selector. The error string gets shown to the
          // user on the cleanup summary.
          var found = describeGPButtons(40).join(' || ');
          return {
            ok: false,
            error: 'GP trash button not found. Buttons visible: ' + found.substring(0, 600)
          };
        }
        fullClick(trash);

        // 3. Wait for the confirmation. GP doesn't always show a dialog —
        // sometimes the trash happens immediately. Detect either case:
        //   a) confirm button in a dialog: click it
        //   b) selection toolbar disappears: assume immediate trash success
        var confirmed = await clickGPTrashConfirm(4000);
        if (!confirmed) {
          var stillThere = findGPTrashButton();
          if (!stillThere) {
            return { ok: true };  // delete succeeded without confirm dialog
          }
          return { ok: false, error: 'GP trash-confirm dialog did not appear' };
        }
        return { ok: true };
      };

      // reloadKeepingScroll: save BOTH the anchor photo ID (most reliable)
      // and the pixel scrollY (fallback), then reload. The scroll-restore
      // block at the top of this user script picks them up after the
      // reload completes and seeks back to the same spot as GP's
      // virtualized content streams in. Called by Swift only after a
      // successful bulk delete RPC, so the in-flight fetch isn't killed.
      window.__photoCleanerReloadKeepingScroll = function () {
        try {
          // Find the topmost photo that's currently visible — its ID makes
          // a much more reliable scroll anchor than raw pixel position on
          // virtualized content.
          var anchors = document.querySelectorAll('a[href*="/photo/"]');
          var anchorId = null;
          for (var i = 0; i < anchors.length; i++) {
            var rect = anchors[i].getBoundingClientRect();
            if (rect.bottom > 10 && rect.top < window.innerHeight - 10) {
              var m = /\/photo\/([^/?#]+)/.exec(anchors[i].href);
              if (m) { anchorId = m[1]; break; }
            }
          }
          if (anchorId) {
            sessionStorage.setItem('pc_anchorPhotoId', anchorId);
          }
          sessionStorage.setItem('pc_savedScroll', String(window.scrollY));
          window.location.reload();
        } catch (e) {}
      };

      // ---- Random pool harvester ----------------------------------------
      // Visits RANDOM positions across the user's entire library so the
      // candidate pool covers more than just the most-recent N photos.
      //
      // GP virtualizes — scrollHeight only grows as you actually scroll
      // down. So we first do 4 jumps to the current bottom to expand the
      // measurable scroll range, THEN hop to random Y positions and
      // collect at each. Result: a diverse pool spanning years of history.
      window.__photoCleanerHarvestPool = async function (targetCount) {
        var n = parseInt(targetCount, 10) || 50;
        // Aim for ~5x what we need so the random pick has real variety
        // even with overlap between visits.
        var poolTarget = Math.max(n * 5, n + 150);

        var scroller = await findGPScrollContainer();
        var originalY = scrollerY(scroller);
        var collected = Object.create(null);

        function collectAll() {
          var anchors = document.querySelectorAll('a[href*="/photo/"]');
          for (var i = 0; i < anchors.length; i++) {
            var a = anchors[i];
            var id = extractId(a.getAttribute('href') || a.href);
            if (!id || collected[id]) continue;
            collected[id] = {
              id: id,
              thumbUrl: thumbFrom(a),
              label: a.getAttribute('aria-label') || ''
            };
          }
        }
        function count() { return Object.keys(collected).length; }

        collectAll();

        // ---- Phase 1: EXHAUST the scrollable range ----------------
        // GP virtualizes — scrollHeight only grows as content streams
        // in. Keep jumping to bottom until scrollHeight stops growing
        // for 3 consecutive jumps, which means we've actually reached
        // the bottom of the library (not just the bottom of what's
        // streamed so far).
        //
        // This is what makes random ACTUALLY random across the whole
        // library instead of just the most recent ~400 photos.
        var lastMaxY = -1;
        var stable = 0;
        var phase1Iter = 0;
        var phase1Cap = 25;  // hard cap (~8s at 320ms/iter) for safety
        while (stable < 3 && phase1Iter < phase1Cap) {
          phase1Iter++;
          scrollerTo(scroller, scrollerMax(scroller) + 5000);
          await new Promise(function (r) { setTimeout(r, 320); });
          collectAll();
          var nowMax = scrollerMax(scroller);
          if (nowMax === lastMaxY) {
            stable++;
          } else {
            stable = 0;
            lastMaxY = nowMax;
          }
        }
        var maxY = scrollerMax(scroller);

        // ---- Phase 2: visit random positions ----------------------
        // With maxY now covering the full library, random Y picks span
        // the user's entire history — not just the top.
        var visits = 16;
        for (var v = 0; v < visits && count() < poolTarget; v++) {
          var y = maxY > 100
            ? Math.floor(Math.random() * maxY)
            : 0;
          scrollerTo(scroller, y);
          await new Promise(function (r) { setTimeout(r, 220); });
          collectAll();
        }

        // ---- Phase 3: top-up if still short -----------------------
        // Walk down from a random start in case the random visits didn't
        // hit enough new anchors.
        if (count() < n) {
          var startY = Math.floor(Math.random() * Math.max(maxY * 0.5, 1));
          scrollerTo(scroller, startY);
          await new Promise(function (r) { setTimeout(r, 200); });
          var topupSafety = 30;
          while (topupSafety-- > 0 && count() < n) {
            var beforeY = scrollerY(scroller);
            scrollerTo(scroller, beforeY + Math.max(scrollerH(scroller) * 0.9, 600));
            await new Promise(function (r) { setTimeout(r, 160); });
            collectAll();
            if (scrollerY(scroller) === beforeY) break;
          }
        }

        // Restore scroll position.
        scrollerTo(scroller, originalY);

        var out = [];
        for (var k in collected) out.push(collected[k]);
        return out;
      };

      // ---- TRUE-random batch via EzkLib date sampling --------------------
      // This bypasses GP's DOM entirely. Picks random ms timestamps across
      // the user's full library lifespan (from rJ0tlb sniff), formats each
      // as a date string, calls EzkLib per date in parallel, then pools /
      // dedupes / shuffles. Result is uniform random across thousands of
      // photos in ~1-2s, regardless of where the user is scrolled in GP.
      var MONTH_NAMES = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
      ];
      function formatDateForEzkLib(ms) {
        var d = new Date(ms);
        return MONTH_NAMES[d.getMonth()] + ' ' + d.getDate() + ', ' + d.getFullYear();
      }

      window.__photoCleanerRandomBatchByDate = async function (targetCount, oldestMsArg, newestMsArg) {
        var n = parseInt(targetCount, 10) || 25;
        var oldest = parseInt(oldestMsArg, 10);
        var newest = parseInt(newestMsArg, 10);
        if (!oldest || !newest || newest <= oldest) {
          return {
            ok: false,
            error: 'invalid date bounds (oldest=' + oldest + ' newest=' + newest + ')'
          };
        }
        var range = newest - oldest;
        var picked = Object.create(null);
        var datesQueried = Object.create(null);
        var totalAttempts = 0;
        var maxAttempts = 30;  // 30 rounds * 4 dates = up to 120 EzkLib calls
        var lastError = '';

        while (Object.keys(picked).length < n && totalAttempts < maxAttempts) {
          totalAttempts++;

          // Pick 4 random ms positions we haven't already queried.
          var batch = [];
          var batchTries = 0;
          while (batch.length < 4 && batchTries < 20) {
            batchTries++;
            var randomMs = oldest + Math.floor(Math.random() * range);
            var ds = formatDateForEzkLib(randomMs);
            if (datesQueried[ds]) continue;
            datesQueried[ds] = true;
            batch.push(ds);
          }
          if (batch.length === 0) break;  // ran out of fresh dates

          var results = await Promise.all(batch.map(function (ds) {
            return searchByDateCached(ds).catch(function (e) {
              lastError = (e && e.message) ? e.message : String(e);
              return [];
            });
          }));

          for (var j = 0; j < results.length; j++) {
            // Shuffle within each date so we don't always pick the first
            // photo of every random date.
            var photos = results[j].slice().sort(function () {
              return Math.random() - 0.5;
            });
            for (var k = 0; k < photos.length; k++) {
              var ph = photos[k];
              if (!ph.id || picked[ph.id]) continue;
              picked[ph.id] = ph;
              if (Object.keys(picked).length >= n) break;
            }
            if (Object.keys(picked).length >= n) break;
          }
        }

        // Convert to GPPhoto-compatible shape. Construct a label that
        // matches the regex in Swift's `GPPhoto.dateString`
        // (`<Word> <Day>, <Year>`) so the EzkLib date-search at delete
        // time can find these photos again.
        var out = [];
        for (var id in picked) {
          var p = picked[id];
          var labelDate = p.createTime
            ? formatDateForEzkLib(p.createTime)
            : formatDateForEzkLib(Date.now());
          var prefix = p.isVideo ? 'Video' : 'Photo';
          out.push({
            id: p.id,
            thumbUrl: p.thumbUrl || '',
            label: prefix + ' - ' + labelDate,
            sizeBytes: p.sizeBytes || 0
          });
        }
        // Final shuffle across all collected.
        out.sort(function () { return Math.random() - 0.5; });
        if (out.length > n) out = out.slice(0, n);

        return {
          ok: true,
          photos: out,
          attempted: totalAttempts,
          datesTried: Object.keys(datesQueried).length,
          collected: out.length,
          lastError: lastError
        };
      };

      // (eNG3nf RPC and its helpers were removed — Google returns
      // PERMISSION_DENIED [3] for non-first-party callers. Library total
      // and date bounds now come from the document-start rJ0tlb sniffer.)

      // ---- Diagnose ---------------------------------------------------------
      // Page-state snapshot so we can see whether WIZ tokens are present and
      // what kind of photo IDs the rendered DOM exposes.
      window.__photoCleanerDiagnose = function () {
        var anchors = document.querySelectorAll('a[href*="/photo/"]');
        var first = anchors[0] || null;
        var firstHref = first ? (first.getAttribute('href') || first.href) : null;
        var idMatch = firstHref ? /\/photo\/([^/?#]+)/.exec(firstHref) : null;
        var firstId = idMatch ? idMatch[1] : null;
        var w = window.WIZ_global_data || null;
        var wizKeys = w ? Object.keys(w).slice(0, 30) : [];
        var ua = navigator.userAgent.substring(0, 80);
        return {
          pageURL: location.href,
          ua: ua,
          anchorCount: anchors.length,
          firstHref: firstHref,
          firstId: firstId,
          firstIdLength: firstId ? firstId.length : 0,
          wizPresent: !!w,
          wizKeyCount: wizKeys.length,
          wizKeys: wizKeys,
          hasAtToken: !!(w && w['SNlM0e']),
          hasBlToken: !!(w && w['cfb2h']),
          hasSidToken: !!(w && w['FdrFJe'])
        };
      };
    })();
    """#

    func makeUIView(context: Context) -> WKWebView {
        // Re-use the controller's existing WebView if one's already alive.
        // This is what makes the second/third visit to Connect Google Photos
        // feel instant — the page is still loaded from last time, cookies
        // are warm, no reload happens.
        if let existing = controller.webView {
            existing.removeFromSuperview()
            existing.navigationDelegate = context.coordinator
            return existing
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Tell WebKit to behave like Safari's "Request Desktop Website" mode —
        // this combines the desktop UA with desktop viewport handling so GP
        // serves us the full web app instead of the mobile lite variant.
        config.defaultWebpagePreferences.preferredContentMode = .desktop

        // 1. rJ0tlb fetch+XHR sniffer at document START — must run before
        //    Google's bootstrap JS so it wraps the network APIs in time
        //    to catch the rJ0tlb response. Pairs with a Swift-side
        //    messageHandler that parses + persists what it captures.
        let rJ0Script = WKUserScript(
            source: Self.rJ0SnifferJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(rJ0Script)
        // The message handler is the bridge: every captured rJ0tlb
        // response body lands in Coordinator.userContentController(_:didReceive:).
        config.userContentController.add(context.coordinator, name: "rJ0tlbCapture")

        // 2. Main harvester + RPC bundle at document END.
        let userScript = WKUserScript(
            source: Self.userScriptJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUA
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        // Let users pinch out to see the full desktop GP layout if they need
        // to navigate to a search/date that isn't visible in the cropped view.
        webView.scrollView.minimumZoomScale = 0.25
        webView.scrollView.maximumZoomScale = 3.0
        controller.webView = webView

        // Skip the ServiceLogin redirect on subsequent app launches once
        // we've successfully landed on photos.google.com at least once.
        // First-time users still go through the proper sign-in flow.
        let hasSignedInBefore = UserDefaults.standard.bool(forKey: "gpHasSignedIn")
        let initialURL: URL
        if hasSignedInBefore {
            initialURL = URL(string: "https://photos.google.com/")!
        } else {
            initialURL = URL(string: GooglePhotosWebController.signInURLString)!
        }
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: GooglePhotosWebView

        init(_ parent: GooglePhotosWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                parent.isLoading = true
                parent.currentURL = webView.url
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                parent.isLoading = false
                parent.currentURL = webView.url
                parent.pageTitle = webView.title
            }
            // Belt-and-suspenders cookie flush.
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { _ in }
            // Remember that the user reached photos.google.com so the next
            // app launch can skip ServiceLogin (saves ~500ms redirect).
            if let host = webView.url?.host?.lowercased(), host == "photos.google.com" {
                UserDefaults.standard.set(true, forKey: "gpHasSignedIn")
                // Schedule a nudge: if no rJ0tlb arrives within 3s,
                // reload ONCE to re-trigger bootstrap. Persisted WebViews
                // that were already loaded in a prior session won't
                // refire rJ0tlb without this nudge. The hasNudged guard
                // is essential — without it, every reload's didFinish
                // scheduled another reload whenever capture kept failing:
                // an infinite reload loop that yanked the page out from
                // under the user every few seconds.
                Task { @MainActor [weak controller = parent.controller, weak webView] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let controller, let webView else { return }
                    if controller.libraryTotal == nil, !controller.hasNudged {
                        controller.markNudgePerformed()
                        webView.reload()
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in parent.isLoading = false }
        }

        // MARK: - WKScriptMessageHandler (rJ0tlb sniffer bridge)

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "rJ0tlbCapture",
                  let body = message.body as? String else { return }
            Task { @MainActor in
                parent.controller.ingestRJ0Response(rawText: body)
            }
        }
    }
}
