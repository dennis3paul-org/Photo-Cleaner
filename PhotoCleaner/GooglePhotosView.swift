import SwiftUI

struct GooglePhotosView: View {
    @EnvironmentObject var appModel: AppModel

    /// Uses the app-lifetime singleton on AppModel (not a @StateObject) so the
    /// WKWebView and its loaded page persist across visits — re-opening
    /// Connect Google Photos doesn't trigger a fresh reload.
    private var controller: GooglePhotosWebController { appModel.gpWebController }

    @State private var currentURL: URL?
    @State private var pageTitle: String?
    @State private var isLoading: Bool = false
    @State private var gpSelectedCount: Int = 0
    @State private var pollTimer: Timer?
    @State private var showSelectionMismatch: Bool = false
    @State private var lastDebug: String?
    @State private var isRandomLoading: Bool = false
    @State private var isHarvesting: Bool = false
    @State private var randomError: String?
    @State private var showRandomError: Bool = false

    /// Random-pick batch sizes shown in the GP "🎲 Random" pill menu.
    private let randomCounts: [Int] = [10, 25, 50, 100, 200]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                ZStack(alignment: .bottom) {
                    GooglePhotosWebView(
                        controller: controller,
                        currentURL: $currentURL,
                        pageTitle: $pageTitle,
                        isLoading: $isLoading
                    )
                    if appModel.phase == .googlePhotos && isOnPhotosHost {
                        bottomBar
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)

            // Overlays
            if appModel.phase == .googleSwipe {
                GPSwipeView(prefetchAction: {
                    await controller.prefetchActionTokens(for: appModel.gpPhotos)
                })
                    .background(Color(.systemBackground))
                    .transition(.opacity)
            } else if appModel.phase == .googleCleanup {
                GPCleanupView(
                    bulkDeleteAction: { photos, concurrency in
                        try await controller.bulkDelete(photos: photos, concurrency: concurrency)
                    },
                    progressAction: {
                        await controller.bulkProgress()
                    },
                    hideDeletedAction: { ids in
                        await controller.hideDeletedPhotos(ids)
                    },
                    nativeDeleteAction: { keepIds, expectedCount in
                        await controller.deleteViaNativeUI(
                            keepIds: keepIds, expectedDeleteCount: expectedCount
                        )
                    },
                    diagnoseAction: {
                        await controller.diagnose()
                    }
                )
                .background(Color(.systemBackground))
                .transition(.opacity)
            }

            // Full-screen loading overlay while a batch is being built —
            // random pick (may reload the WebView to recapture rJ0tlb
            // bounds) or the deep-scroll selection harvest (visibly
            // scrolls the whole grid, up to tens of seconds on big
            // selections). LAST in the ZStack + zIndex so it stays on
            // top through the phase-overlay crossfade — previously the
            // WebView peeked through mid-transition.
            if isRandomLoading || isHarvesting {
                loadingOverlay(
                    title: isHarvesting ? "Collecting your selection…" : "Building random batch…",
                    subtitle: isHarvesting ? "Scanning the photo grid" : "Sampling across your library"
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appModel.phase)
        .animation(.easeInOut(duration: 0.2), value: gpSelectedCount > 0)
        .animation(.easeInOut(duration: 0.2), value: isRandomLoading)
        .animation(.easeInOut(duration: 0.2), value: isHarvesting)
        .task {
            // Sync state from the (possibly reused) WebView so the toolbar
            // immediately shows "Reload" instead of flashing "Sign in" when
            // the cached page is already on photos.google.com.
            if let url = controller.currentLoadedURL {
                currentURL = url
                pageTitle = controller.currentPageTitle
            }
            startPolling()
        }
        .onDisappear { pollTimer?.invalidate() }
        .onChange(of: appModel.phase) { _, newPhase in
            // The selection poll only matters while the user is browsing
            // GP. During swipe/cleanup phases the old guard skipped the
            // JS eval but the timer kept waking the CPU every 0.7s for
            // the whole (potentially long) triage session — pause it
            // outright and resume on return.
            if newPhase == .googlePhotos {
                startPolling()
            } else {
                pollTimer?.invalidate()
                pollTimer = nil
            }
        }
        .sheet(isPresented: $showSelectionMismatch) {
            mismatchSheet
        }
        .alert("Random pick failed", isPresented: $showRandomError, presenting: randomError) { _ in
            Button("OK") { showRandomError = false }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                appModel.phase = .idle
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Library")
                }
                .font(.body.weight(.medium))
            }
            Spacer()
            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Text("Google Photos")
                        .font(.headline)
                }
                if let signal = statusLine {
                    Text(signal)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                if isOnPhotosHost {
                    controller.reload()
                } else {
                    controller.navigateToSignIn()
                }
            } label: {
                Text(isOnPhotosHost ? "Reload" : "Sign in")
                    .font(.body.weight(.medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Loading overlay

    /// Full-screen opaque overlay shown while a triage batch is being
    /// built. Hides any visible scrolling / reloading happening behind it
    /// (rJ0tlb refresh reload, deep-harvest grid scrolling, EzkLib RPC
    /// fan-out) so the experience is just "tap → loading → triage".
    private func loadingOverlay(title: String, subtitle: String) -> some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if gpSelectedCount > 0 {
                triageButton
            } else {
                instructionPill
            }
            randomPill
        }
    }

    private var randomPill: some View {
        Menu {
            ForEach(randomCounts, id: \.self) { n in
                Button("Random \(n)") {
                    Task { await startRandomTriage(count: n) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if isRandomLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "shuffle")
                }
                Text(isRandomLoading ? "Picking…" : "Random")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .opacity(0.7)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.75), in: Capsule())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
        .disabled(isRandomLoading)
    }

    private var instructionPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap")
            Text("Long-press a photo in Google Photos to start selecting")
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.75), in: Capsule())
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private var triageButton: some View {
        Button {
            Task { await startTriage() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack")
                Text("Triage \(gpSelectedCount) selected")
                Spacer()
                Image(systemName: "arrow.right")
            }
            .font(.headline)
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
    }

    // MARK: Actions

    private func startTriage() async {
        guard !isHarvesting else { return }
        // The deep-scroll harvester drives the GP grid top-to-bottom to
        // materialize virtualized selections — visible scrolling that can
        // take many seconds on a big selection. Cover it with the opaque
        // loading overlay (same treatment as random pick) so the user sees
        // a clean "collecting…" state instead of the page thrashing.
        isHarvesting = true
        let selected = await controller.gpGetSelectedDeep()
        if selected.isEmpty {
            isHarvesting = false
            // GP's header says photos are selected but our DOM scan came up
            // empty — surface a diagnostic instead of triaging zero photos.
            lastDebug = await controller.gpSelectionDebug()
            showSelectionMismatch = true
            return
        }
        prewarmFirstVideos(in: selected)
        appModel.startGPTriage(selected)
        dropOverlayAfterTransition { isHarvesting = false }
    }

    /// Kick off URLSession downloads for the first ~2 video URLs in the
    /// batch BEFORE the triage view appears. This is the only way the
    /// very-first card gets a head start — once triage is on screen, its
    /// WebView mounts immediately and would otherwise race the prefetch.
    /// Fire-and-forget; the prefetcher dedupes if .onAppear in the swipe
    /// view also asks for the same URLs.
    private func prewarmFirstVideos(in photos: [GPPhoto]) {
        let videos = photos.filter { $0.isVideo }.prefix(2)
        for photo in videos {
            guard let videoURL = photo.videoURL else { continue }
            VideoFilePrefetcher.shared.prefetch(videoURL, posterURL: photo.enlargedURL)
        }
    }

    /// Keep the loading overlay up until the swipe view has fully faded
    /// in (0.2s phase crossfade), THEN drop it. Dropping it in the same
    /// transaction as the phase change let the WebView peek through the
    /// crossfade for a couple of frames.
    private func dropOverlayAfterTransition(_ clear: @escaping () -> Void) {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            clear()
        }
    }

    /// Build a truly random batch using the EzkLib-by-date sampler. Picks
    /// random ms positions across the user's entire library lifespan
    /// (bounds come from the rJ0tlb sniff), queries EzkLib per date, and
    /// pools the results. Uniform random across THE WHOLE library — same
    /// approach the Chrome extension uses.
    ///
    /// If rJ0tlb bounds aren't captured yet (persistent WebView from a
    /// prior session, sniff missed the bootstrap), we proactively reload
    /// the WebView to force a fresh capture and wait up to 8s.
    private func startRandomTriage(count: Int) async {
        guard !isRandomLoading else { return }
        isRandomLoading = true

        // If bounds aren't captured yet, nudge a reload and wait.
        if controller.oldestMs == nil || controller.newestMs == nil {
            controller.forceRJ0Refresh()
            _ = await controller.waitForRJ0(seconds: 8)
        }

        let result = await controller.gpRandomBatchByDate(count: count)
        if result.photos.isEmpty {
            isRandomLoading = false
            randomError = result.error ??
                "Couldn't build a random batch. Make sure you're signed into Google Photos."
            showRandomError = true
            return
        }
        prewarmFirstVideos(in: result.photos)
        appModel.startGPTriage(result.photos)
        // Overlay comes down only after the swipe view has faded in —
        // a `defer` here dropped it mid-crossfade and the (possibly
        // mid-reload) WebView flashed through.
        dropOverlayAfterTransition { isRandomLoading = false }
    }

    // MARK: Polling

    /// Poll GP's selection state every ~700ms so the toolbar count tracks
    /// what the user is selecting in GP's UI.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
            Task { @MainActor in
                guard appModel.phase == .googlePhotos,
                      !isRandomLoading, !isHarvesting else { return }
                gpSelectedCount = await controller.gpSelectedCount()
            }
        }
        timer.tolerance = 0.2
        pollTimer = timer
    }

    // MARK: Mismatch diagnostic sheet

    private var mismatchSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
                .padding(.top, 32)
            Text("Couldn't read selected photos")
                .font(.title3.bold())
            Text("Google Photos shows photos as selected but our DOM scan couldn't find them. Paste this back so we can refine the selectors:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            ScrollView {
                Text(lastDebug ?? "(no debug)")
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            Button {
                if let lastDebug { UIPasteboard.general.string = lastDebug }
            } label: {
                Label("Copy debug", systemImage: "doc.on.doc")
            }
            Spacer()
            Button {
                showSelectionMismatch = false
            } label: {
                Text("Close")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Computed

    private var isOnPhotosHost: Bool {
        guard let host = currentURL?.host?.lowercased() else { return false }
        return host == "photos.google.com"
    }

    private var statusLine: String? {
        guard let host = currentURL?.host?.lowercased() else { return nil }
        if host.contains("accounts.google.") { return "Signing in…" }
        if host == "photos.google.com" {
            if gpSelectedCount > 0 { return "\(gpSelectedCount) selected" }
            return (pageTitle?.isEmpty == false) ? pageTitle : "Connected"
        }
        return host
    }
}
