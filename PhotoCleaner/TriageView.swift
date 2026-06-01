import Photos
import SwiftUI

/// Local PhotoKit triage. Swipe-card UI over the assets chosen on PickBatchView.
/// Left = mark for delete, right = keep. The actual deletion happens on
/// LocalCleanupView via PHAssetChangeRequest.deleteAssets (single iOS-system
/// confirmation dialog covers the entire batch).
struct TriageView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var flyCommand: SwipeDecision?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appModel.localAssets.isEmpty {
                emptyState
            } else if appModel.localCursor >= appModel.localAssets.count {
                summary
            } else {
                cardArea
            }
        }
        .onShake {
            appModel.undoLocal()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                appModel.phase = .pickBatch
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Batches")
                }
                .font(.body.weight(.medium))
            }
            Spacer()
            VStack(spacing: 1) {
                Text(appModel.selectedScope?.title ?? "Triage")
                    .font(.headline)
                Text(progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appModel.undoLocal()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Undo")
                }
                .font(.body.weight(.medium))
            }
            .disabled(appModel.localHistory.isEmpty)
            .opacity(appModel.localHistory.isEmpty ? 0.3 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var progressLabel: String {
        let total = appModel.localAssets.count
        let done = min(appModel.localCursor, total)
        return "\(done) / \(total)"
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No photos in this batch")
                .font(.headline)
            Spacer()
        }
    }

    private var summary: some View {
        let deleteBytes = appModel.localDeleteQueue
            .reduce(into: Int64(0)) { $0 += $1.fileSizeBytes }
        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Triage complete")
                .font(.title2.bold())
            VStack(spacing: 4) {
                Text("\(appModel.localDeleteQueue.count) marked for delete")
                if deleteBytes > 0 {
                    Text("Will free \(FileSize.format(deleteBytes))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .monospacedDigit()
                }
                Text("\(appModel.localKeepCount) kept")
                    .foregroundStyle(.secondary)
            }
            .font(.body)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    appModel.phase = .cleanup
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete \(appModel.localDeleteQueue.count) photos")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        appModel.localDeleteQueue.isEmpty ? Color.gray.opacity(0.3) : Color.red,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundStyle(.white)
                }
                .disabled(appModel.localDeleteQueue.isEmpty)

                Button {
                    appModel.resetLocalTriage()
                    appModel.phase = .idle
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
                    // ID by stable localIdentifier (not the offset) so
                    // SwipeCards persist across stack-position changes —
                    // see GPSwipeView for the rationale.
                    ForEach(visibleSlice.reversed(), id: \.1.localIdentifier) { offset, asset in
                        SwipeCard(
                            label: asset.triageLabel,
                            sizeLabel: FileSize.format(asset.fileSizeBytes),
                            isVideo: asset.mediaType == .video,
                            stackOffset: offset,
                            cardSize: proxy.size,
                            flyCommand: $flyCommand,
                            onDecision: { handle($0) }
                        ) {
                            PHAssetImage(asset: asset, targetSize: proxy.size)
                        }
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

    private var visibleSlice: [(Int, PHAsset)] {
        let start = appModel.localCursor
        let end = min(start + 3, appModel.localAssets.count)
        guard start < end else { return [] }
        return (start..<end).enumerated().map { ($0.offset, appModel.localAssets[$0.element]) }
    }

    private func handle(_ decision: SwipeDecision) {
        guard appModel.localCursor < appModel.localAssets.count else { return }
        let asset = appModel.localAssets[appModel.localCursor]
        appModel.localHistory.append(LocalDecisionRecord(asset: asset, decision: decision))
        switch decision {
        case .delete: appModel.localDeleteQueue.append(asset)
        case .keep:   appModel.localKeepCount += 1
        }
        withAnimation(.spring(duration: 0.25)) {
            appModel.localCursor += 1
        }
    }
}
