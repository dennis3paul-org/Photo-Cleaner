import SwiftUI

/// `AsyncImage` with auto-retry on failure. The vanilla AsyncImage gives
/// up after one attempt and stays in `.failure` forever — so a transient
/// CDN blip on a GP thumbnail (which we see occasionally — Google's
/// `lh3.googleusercontent.com` serves brief 4xx/5xx for hot photos)
/// becomes a permanent broken card the user has to swipe past.
///
/// This wrapper retries up to `maxRetries` times with `retryDelay`
/// between attempts. Each retry appends a cache-busting query param
/// so iOS's URLCache doesn't just hand back the cached failure
/// response.
///
/// Falls back to `placeholder` after all retries fail.
struct RetryingAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let maxRetries: Int
    let retryDelay: Double  // seconds
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var attempt: Int = 0
    @State private var retryScheduled: Bool = false

    init(
        url: URL?,
        maxRetries: Int = 2,
        retryDelay: Double = 0.5,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        AsyncImage(url: urlForAttempt) { phase in
            switch phase {
            case .success(let image):
                content(image)
            case .empty:
                placeholder()
            case .failure:
                placeholder()
                    .onAppear { scheduleRetry() }
            @unknown default:
                placeholder()
            }
        }
        // Re-mount on each retry. Without `.id`, SwiftUI may keep the
        // existing AsyncImage which already cached the .failure result
        // and just won't try again.
        .id(attempt)
    }

    /// On retries > 0, append `_r=N` to the URL. GP CDN URLs of the
    /// form `lh3.googleusercontent.com/HASH=w1200-h1200` don't normally
    /// carry a query string; adding one bypasses URLCache (cache key
    /// includes the query) and the server ignores the unknown param.
    private var urlForAttempt: URL? {
        guard let url else { return nil }
        guard attempt > 0,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "_r", value: String(attempt)))
        comps.queryItems = items
        return comps.url ?? url
    }

    private func scheduleRetry() {
        guard attempt < maxRetries, !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
            attempt += 1
            retryScheduled = false
        }
    }
}
