import SwiftUI

struct IdleView: View {
    @EnvironmentObject var photoService: PhotoLibraryService
    @EnvironmentObject var appModel: AppModel

    /// Mirror of `appModel.gpWebController.libraryTotal`, kept in @State so
    /// SwiftUI re-renders the GP card when the controller's @Published
    /// fires. We sync via .onReceive on the publisher — that's the right
    /// way to observe a nested ObservableObject reached through an
    /// EnvironmentObject without rebuilding the parent.
    @State private var gpTotal: Int?
    @State private var gpTotalError: String?
    @State private var showErrorSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Photo Cleaner")
                    .font(.largeTitle.bold())
                Text("Triage your library, fast.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            Spacer()

            VStack(spacing: 14) {
                LibraryCard(
                    title: "Local Photos",
                    subtitle: "Stored on this device",
                    countLabel: localCountLabel,
                    iconView: AnyView(localIcon)
                ) {
                    appModel.phase = .pickBatch
                }

                LibraryCard(
                    title: "Google Photos",
                    subtitle: gpSubtitle,
                    countLabel: gpCountLabel,
                    iconView: AnyView(
                        GooglePhotosLogo()
                            .frame(width: 38, height: 38)
                    )
                ) {
                    // If we're stuck on a count error, tapping the card
                    // opens the diagnostic sheet INSTEAD of routing into
                    // GP — so the user can copy the response details for
                    // us to debug. (Normal tap routes to GP.)
                    if gpTotal == nil, gpTotalError != nil {
                        showErrorSheet = true
                    } else {
                        appModel.phase = .googlePhotos
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .task {
            // Seed from whatever's already cached on the controller.
            // libraryTotal may be present from UserDefaults TTL even on
            // cold launch — that's the fast path so the GP card never
            // shows "Connecting…" if we have a recent rJ0tlb cached.
            gpTotal = appModel.gpWebController.libraryTotal
            gpTotalError = appModel.gpWebController.libraryTotalError
        }
        .onReceive(appModel.gpWebController.$libraryTotal) { newValue in
            gpTotal = newValue
        }
        .onReceive(appModel.gpWebController.$libraryTotalError) { newValue in
            gpTotalError = newValue
        }
        .sheet(isPresented: $showErrorSheet) {
            errorSheet
        }
    }

    // MARK: Local card values

    @ViewBuilder
    private var localIcon: some View {
        Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 38, height: 38)
    }

    private var localCountLabel: String {
        if !photoService.isAuthorized { return "Tap to allow" }
        return photoService.totalCount.formatted(.number)
    }

    // MARK: GP card values

    private var gpSubtitle: String {
        if gpTotal != nil { return "Library total" }
        let onGP: Bool = {
            if let host = appModel.gpWebController.currentLoadedURL?.host?.lowercased(),
               host == "photos.google.com" { return true }
            return false
        }()
        if gpTotalError != nil, onGP {
            return "Count error — tap for details"
        }
        if onGP { return "Connecting…" }
        return "Sign in to connect"
    }

    // MARK: Error sheet

    private var errorSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .padding(.top, 24)
            Text("Couldn't fetch GP library count")
                .font(.title3.bold())
            Text("Below is the raw response from Google's eNG3nf RPC. Copy and share this to help debug.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            ScrollView {
                Text(gpTotalError ?? "(no error)")
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            HStack(spacing: 12) {
                Button {
                    if let e = gpTotalError { UIPasteboard.general.string = e }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                Button {
                    // Force a fresh WebView load — rJ0tlb fires on
                    // bootstrap, and the sniffer pushes the new response
                    // to the controller via the messageHandler bridge.
                    appModel.gpWebController.forceRJ0Refresh()
                    Task {
                        _ = await appModel.gpWebController.waitForRJ0(seconds: 8)
                        gpTotal = appModel.gpWebController.libraryTotal
                        gpTotalError = appModel.gpWebController.libraryTotalError
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 16)
            Button {
                showErrorSheet = false
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
            Spacer(minLength: 0)
        }
        .presentationDetents([.medium, .large])
    }

    private var gpCountLabel: String {
        if let n = gpTotal { return n.formatted(.number) }
        return "—"
    }
}

// MARK: - Card

/// Equal-weight library entry card. Used for both Local Photos and Google
/// Photos so the main screen reads as "two parallel sources, pick one."
private struct LibraryCard: View {
    let title: String
    let subtitle: String
    let countLabel: String
    let iconView: AnyView
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                iconView
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(countLabel)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: countLabel)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
