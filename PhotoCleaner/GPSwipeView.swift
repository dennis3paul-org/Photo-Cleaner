import SwiftUI
import WebKit

/// Tinder-style swipe over a list of Google Photos. Left = mark for delete,
/// right = keep. Designed to be rendered as an overlay on GooglePhotosView so
/// the WebView (and its WIZ tokens) stays alive underneath for the cleanup
/// phase.
struct GPSwipeView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var flyCommand: SwipeDecision?
    /// Bumped on card tap; WebVideoPlayer fires an immediate play() kick
    /// when it changes. The tap-to-play listener INSIDE the WebView is
    /// unreachable (the player is .allowsHitTesting(false) so drags feel
    /// native), and Low Power Mode blocks autoplay at the system level —
    /// this is the user's manual escape hatch for a stuck video.
    @State private var playKick: Int = 0

    /// Background pre-warm of action tokens; runs once when the view appears
    /// so the bulk-delete RPC at the end of triage has zero setup cost.
    let prefetchAction: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appModel.gpPhotos.isEmpty {
                emptyState
            } else if appModel.gpCursor >= appModel.gpPhotos.count {
                summary
            } else {
                cardArea
            }
        }
        .task {
            // Warm the EzkLib cache while the user is swiping. By the time
            // they tap Delete, every action token is already in memory.
            await prefetchAction()
        }
        .onAppear {
            // First prefetch round: start downloading the first 2 videos
            // straight to local tmp files via URLSession (Path B). By the
            // time the visible WebView mounts <video src=…>, the file is
            // ready and playback starts in ~50-100ms instead of ~500ms.
            triggerVideoPrefetch()
        }
        .onChange(of: appModel.gpCursor) { _, _ in
            // Every swipe / undo / button-tap shifts upcomingVideos —
            // prefetch the new window.
            triggerVideoPrefetch()
        }
        .onDisappear {
            // Clean up tmp video files — don't let triage sessions stack
            // up disk usage. Cache regenerates on next swipe session.
            VideoFilePrefetcher.shared.clearCache()
        }
        .onShake {
            // iOS shake-to-undo, matching native UIKit behavior.
            appModel.undoGP()
        }
    }

    /// Kick off `URLSession → file://` downloads for the next 2 videos
    /// AND a URLCache prefetch of their poster thumbnails. The poster
    /// prefetch is what eliminates the black-flash-before-video — by
    /// the time the visible card renders its AsyncImage backdrop, the
    /// URL is already cached and displays instantly.
    private func triggerVideoPrefetch() {
        for photo in upcomingVideos {
            guard let videoURL = photo.videoURL else { continue }
            VideoFilePrefetcher.shared.prefetch(videoURL, posterURL: photo.enlargedURL)
        }
    }

    // MARK: Video prefetch

    /// The next few upcoming videos for URLSession disk prefetch. The
    /// visible card stack already mounts WebVideoPlayer for offsets 0-2
    /// (which start their own loads), so this URLSession download only
    /// needs to stay one or two cards AHEAD of that. Range = next 4.
    private var upcomingVideos: [GPPhoto] {
        let start = appModel.gpCursor + 1
        let end = min(start + 4, appModel.gpPhotos.count)
        guard start < end else { return [] }
        return appModel.gpPhotos[start..<end].filter { $0.isVideo }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                appModel.phase = .googlePhotos
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Library")
                }
                .font(.body.weight(.medium))
            }
            Spacer()
            VStack(spacing: 1) {
                Text("Triage")
                    .font(.headline)
                Text(progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appModel.undoGP()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Undo")
                }
                .font(.body.weight(.medium))
            }
            .disabled(appModel.gpHistory.isEmpty)
            .opacity(appModel.gpHistory.isEmpty ? 0.3 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var progressLabel: String {
        let total = appModel.gpPhotos.count
        let done = min(appModel.gpCursor, total)
        return "\(done) / \(total)"
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No photos to triage")
                .font(.headline)
            Text("Navigate Google Photos to a view you want to clean, then tap Triage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var summary: some View {
        let deleteBytes = appModel.gpDeleteQueue
            .reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Triage complete")
                .font(.title2.bold())
            VStack(spacing: 4) {
                Text("\(appModel.gpDeleteQueue.count) marked for delete")
                if deleteBytes > 0 {
                    Text("Will free \(FileSize.format(deleteBytes))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .monospacedDigit()
                }
                Text("\(appModel.gpKeepCount) kept")
                    .foregroundStyle(.secondary)
            }
            .font(.body)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    appModel.phase = .googleCleanup
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete \(appModel.gpDeleteQueue.count) photos")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        appModel.gpDeleteQueue.isEmpty ? Color.gray.opacity(0.3) : Color.red,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundStyle(.white)
                }
                .disabled(appModel.gpDeleteQueue.isEmpty)

                Button {
                    appModel.resetGPTriage()
                    appModel.phase = .googlePhotos
                } label: {
                    Text("Back to library")
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: Card area

    private var cardArea: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    // ID by the photo's stable string id (NOT the offset
                    // position), so when the cursor advances and a behind-
                    // card slides up to become the new top, SwiftUI keeps
                    // the same SwipeCard instance and just animates its
                    // stackOffset parameter change — no teardown, no flash.
                    ForEach(visibleSlice.reversed(), id: \.1.id) { offset, photo in
                        SwipeCard(
                            label: photo.label,
                            sizeLabel: FileSize.format(photo.sizeBytes),
                            isVideo: photo.isVideo,
                            stackOffset: offset,
                            cardSize: proxy.size,
                            flyCommand: $flyCommand,
                            onDecision: { handle($0) }
                        ) {
                            // Mount WebVideoPlayer for offsets 0 and 1
                            // only. Offset 1's WebView starts loading
                            // while hidden behind the top card, so the
                            // moment the user swipes it's already
                            // painting frames — instant playback.
                            //
                            // Offset 2 used to mount a player too, but
                            // that card is COMPLETELY hidden behind two
                            // opaque cards — its WKWebView + video
                            // decoder burned memory and battery for
                            // pixels no one could see. It now renders
                            // just the poster; its player mounts one
                            // swipe later, still 1+ swipes before
                            // visibility.
                            if let videoURL = photo.videoURL, offset <= 1 {
                                ZStack {
                                    RetryingAsyncImage(
                                        url: photo.enlargedURL,
                                        content: { image in
                                            image.resizable().aspectRatio(contentMode: .fit)
                                        },
                                        placeholder: { Color.clear }
                                    )
                                    WebVideoPlayer(
                                        videoURL: videoURL,
                                        posterURL: nil,  // backdrop handles it
                                        playKick: playKick
                                    )
                                    // Hit-testing disabled: every touch
                                    // (drags, taps, long-presses) skips
                                    // the WKWebView and goes straight to
                                    // the SwipeCard's DragGesture, so GP
                                    // cards feel as snappy as local
                                    // PHAsset cards. Tap-to-play still
                                    // works via the SwiftUI tap below.
                                    .allowsHitTesting(false)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // Manual play kick — the escape hatch
                                    // for autoplay blocked by Low Power
                                    // Mode / decoder contention.
                                    playKick &+= 1
                                }
                            } else {
                                RetryingAsyncImage(
                                    url: photo.enlargedURL,
                                    content: { image in
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    },
                                    placeholder: {
                                        placeholder(systemName: photo.isVideo ? "play.rectangle" : "photo")
                                    }
                                )
                            }
                        }
                        .id(photo.id)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            actionButtons
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 24) {
            actionButton(systemName: "xmark", color: .red, label: "Delete") {
                flyCommand = .delete
            }
            actionButton(systemName: "checkmark", color: .green, label: "Keep") {
                flyCommand = .keep
            }
        }
    }

    private func actionButton(systemName: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(color)
                    .frame(width: 56, height: 56)
                    .background(color.opacity(0.15), in: Circle())
                    .overlay(Circle().stroke(color.opacity(0.4), lineWidth: 1.5))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var visibleSlice: [(Int, GPPhoto)] {
        let start = appModel.gpCursor
        let end = min(start + 3, appModel.gpPhotos.count)
        guard start < end else { return [] }
        return (start..<end).enumerated().map { ($0.offset, appModel.gpPhotos[$0.element]) }
    }

    private func handle(_ decision: SwipeDecision) {
        guard appModel.gpCursor < appModel.gpPhotos.count else { return }
        let photo = appModel.gpPhotos[appModel.gpCursor]
        appModel.gpHistory.append(GPDecisionRecord(photo: photo, decision: decision))
        switch decision {
        case .delete: appModel.gpDeleteQueue.append(photo)
        case .keep:   appModel.gpKeepCount += 1
        }
        withAnimation(.spring(duration: 0.25)) {
            appModel.gpCursor += 1
        }
    }

    @ViewBuilder
    private func placeholder(systemName: String) -> some View {
        ZStack {
            Color.gray.opacity(0.18)
            Image(systemName: systemName)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

}
// URL derivation (enlargedURL / videoURL) lives on GPPhoto itself so the
// swipe cards, the prefetcher pre-warm, and GooglePhotosView all derive
// byte-identical URLs — a mismatch anywhere means the URLCache/file-cache
// prefetch silently never hits.

// Video playback is delegated to WebVideoPlayer (WKWebView-based HTML5 video
// element). We dropped the AVPlayer path because GP's `=dv` media URLs serve
// authenticated cross-origin redirects that AVURLAssetHTTPHeaderFieldsKey
// can't follow with cookies intact — WKWebView's shared cookie jar handles
// it natively.
