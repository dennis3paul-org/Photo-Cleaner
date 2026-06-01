import Photos
import SwiftUI

/// The local-media equivalent of `GooglePhotosView`. A scrollable
/// thumbnail grid of all on-device PHAssets — tap to toggle a selection,
/// then "Triage N selected" runs the swipe flow. The bottom bar matches
/// the GP screen's UX: a Random pill on the left, a Videos-only toggle
/// on the right, and the Triage button takes over when items are picked.
///
/// Replaced the prior "scope rows" layout (Screenshots / Videos /
/// Favorites / etc) because direct gallery browsing is faster + matches
/// what users expect after spending time on the GP screen.
struct PickBatchView: View {
    @EnvironmentObject var appModel: AppModel

    /// Latest PHFetchResult of all media. Re-fetched whenever the
    /// videos-only toggle flips.
    @State private var fetched: PHFetchResult<PHAsset>?
    @State private var selectedIds: Set<String> = []
    @State private var videosOnly: Bool = false
    @State private var isRandomLoading: Bool = false

    /// Caching image manager keeps thumbnail loads cheap as the user
    /// scrolls the grid — pre-warms the visible-ish range so cells don't
    /// flash placeholder → image.
    @State private var cachingManager = PHCachingImageManager()

    /// Random-pick batch sizes, matching the GP screen.
    private let randomCounts: [Int] = [10, 25, 50, 100, 200]

    /// 3-column grid is a good readability/density tradeoff at iPhone widths.
    private let gridSpacing: CGFloat = 3
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 3)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ZStack(alignment: .bottom) {
                galleryGrid
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .task(id: videosOnly) {
            await refetch()
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
                Text("Local Photos")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: headerSubtitle)
            }
            Spacer()
            Button {
                // Quick "deselect all" affordance when there's a selection;
                // otherwise the area is empty for symmetry with the back button.
                if !selectedIds.isEmpty {
                    selectedIds.removeAll()
                }
            } label: {
                Text(selectedIds.isEmpty ? "" : "Clear")
                    .font(.body.weight(.medium))
            }
            .disabled(selectedIds.isEmpty)
            .opacity(selectedIds.isEmpty ? 0 : 1)
            .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var headerSubtitle: String {
        let total = fetched?.count ?? 0
        if selectedIds.isEmpty {
            return "\(total.formatted(.number)) items"
        }
        return "\(selectedIds.count) selected • \(total.formatted(.number)) total"
    }

    // MARK: Gallery grid

    @ViewBuilder
    private var galleryGrid: some View {
        if let fetched, fetched.count > 0 {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                    ForEach(0..<fetched.count, id: \.self) { idx in
                        let asset = fetched.object(at: idx)
                        GalleryCell(
                            asset: asset,
                            isSelected: selectedIds.contains(asset.localIdentifier),
                            cachingManager: cachingManager
                        )
                        .aspectRatio(1, contentMode: .fill)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggle(asset)
                        }
                    }
                }
                .padding(.horizontal, gridSpacing)
                .padding(.top, gridSpacing)
                // Padding so the bottom bar doesn't cover the last row.
                .padding(.bottom, 140)
            }
        } else {
            VStack {
                Spacer()
                Image(systemName: videosOnly ? "video.slash" : "tray")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(videosOnly ? "No videos on device" : "No media on device")
                    .font(.headline)
                    .padding(.top, 8)
                Spacer()
            }
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if !selectedIds.isEmpty {
                triageButton
            }
            HStack(spacing: 10) {
                randomPill
                Spacer()
                videosOnlyToggle
            }
        }
    }

    private var triageButton: some View {
        Button {
            startTriageFromSelection()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack")
                Text("Triage \(selectedIds.count) selected")
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

    private var randomPill: some View {
        Menu {
            ForEach(randomCounts, id: \.self) { n in
                Button("Random \(n)") {
                    Task { await pickRandom(count: n) }
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

    private var videosOnlyToggle: some View {
        Button {
            withAnimation(.snappy) {
                videosOnly.toggle()
                selectedIds.removeAll()  // clear since the visible set changes
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: videosOnly ? "play.fill" : "play")
                Text("Videos only")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                (videosOnly ? Color.accentColor : Color.black.opacity(0.75)),
                in: Capsule()
            )
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
    }

    // MARK: Actions

    private func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// Re-fetch when videosOnly flips or the view first appears. Filter
    /// is applied in the PHFetchOptions predicate so we don't materialize
    /// the wrong-type assets.
    @Sendable
    private func refetch() async {
        let onlyVideos = videosOnly
        let result = await Task.detached(priority: .userInitiated) { () -> PHFetchResult<PHAsset> in
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if onlyVideos {
                return PHAsset.fetchAssets(with: .video, options: opts)
            } else {
                return PHAsset.fetchAssets(with: opts)
            }
        }.value
        fetched = result
    }

    private func startTriageFromSelection() {
        guard let fetched, !selectedIds.isEmpty else { return }
        // Materialize the selected PHAssets in the original sort order
        // so the user triages them top-to-bottom of the grid.
        var picked: [PHAsset] = []
        picked.reserveCapacity(selectedIds.count)
        for i in 0..<fetched.count {
            let a = fetched.object(at: i)
            if selectedIds.contains(a.localIdentifier) {
                picked.append(a)
            }
        }
        guard !picked.isEmpty else { return }
        appModel.startLocalTriage(picked)
    }

    private func pickRandom(count: Int) async {
        guard !isRandomLoading else { return }
        isRandomLoading = true
        defer { isRandomLoading = false }

        let onlyVideos = videosOnly
        let assets = await Task.detached(priority: .userInitiated) { () -> [PHAsset] in
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetched: PHFetchResult<PHAsset> = onlyVideos
                ? PHAsset.fetchAssets(with: .video, options: opts)
                : PHAsset.fetchAssets(with: opts)
            let total = fetched.count
            if total == 0 { return [] }
            if total <= count {
                var all: [PHAsset] = []
                all.reserveCapacity(total)
                fetched.enumerateObjects { a, _, _ in all.append(a) }
                return all
            }
            var chosen = Set<Int>()
            while chosen.count < count {
                chosen.insert(Int.random(in: 0..<total))
            }
            var out: [PHAsset] = []
            out.reserveCapacity(count)
            for i in chosen.sorted() {
                out.append(fetched.object(at: i))
            }
            return out.shuffled()
        }.value

        guard !assets.isEmpty else { return }
        appModel.startLocalTriage(assets)
    }
}

// MARK: - Gallery cell

/// One thumbnail tile in the LazyVGrid. Loads via PHCachingImageManager
/// (much cheaper than a fresh PHImageManager request per cell on every
/// scroll). Selection state is a blue tint + checkmark overlay.
private struct GalleryCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let cachingManager: PHCachingImageManager

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            Color(.systemGray5)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }

            // Video badge in top-right.
            if asset.mediaType == .video {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "play.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.6), in: Circle())
                            .padding(4)
                    }
                    Spacer()
                }
            }

            // Selection overlay.
            if isSelected {
                Color.accentColor.opacity(0.35)
                VStack {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
        .clipped()
        .overlay(
            // Selection border ring so the cell still reads as selected
            // when scrolled fast.
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
        )
        .task(id: asset.localIdentifier) {
            await loadThumbnail()
        }
    }

    @MainActor
    private func loadThumbnail() async {
        let scale = await MainActor.run { UIScreen.main.scale }
        let target = CGSize(width: 200 * scale, height: 200 * scale)
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = true
        opts.resizeMode = .fast

        cachingManager.requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFill,
            options: opts
        ) { result, _ in
            guard let result else { return }
            Task { @MainActor in
                self.thumbnail = result
            }
        }
    }
}
