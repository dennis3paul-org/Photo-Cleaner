import Photos
import SwiftUI

/// Bulk-deletes the local PhotoKit assets the user marked during triage.
/// `PHAssetChangeRequest.deleteAssets` shows the iOS-system "Delete N items?"
/// confirmation dialog once for the entire batch — that's the safety net users
/// expect and there's no way (and no reason) to bypass it.
struct LocalCleanupView: View {
    @EnvironmentObject var appModel: AppModel

    @State private var isRunning: Bool = false
    @State private var hasStarted: Bool = false
    @State private var succeeded: Int = 0
    @State private var bytesFreed: Int64 = 0
    @State private var lastError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                appModel.phase = .triage
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Triage")
                }
                .font(.body.weight(.medium))
            }
            .disabled(isRunning)
            .opacity(isRunning ? 0.4 : 1)
            Spacer()
            VStack(spacing: 1) {
                Text("Cleanup")
                    .font(.headline)
                Text(progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Triage")
            }
            .font(.body.weight(.medium))
            .opacity(0)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var progressLabel: String {
        let total = appModel.localDeleteQueue.count
        return "\(succeeded) / \(total)"
    }

    @ViewBuilder
    private var content: some View {
        let total = appModel.localDeleteQueue.count
        if isRunning {
            runningView(total: total)
        } else if hasStarted {
            summaryView(total: total)
        } else {
            confirmView(total: total)
        }
    }

    private func confirmView(total: Int) -> some View {
        let pendingBytes = appModel.localDeleteQueue
            .reduce(into: Int64(0)) { $0 += $1.fileSizeBytes }
        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "trash.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text("Delete \(total) items?")
                .font(.title2.bold())
            if pendingBytes > 0 {
                Text("Will free \(FileSize.format(pendingBytes))")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .monospacedDigit()
            }
            Text("iOS will show a system confirmation. After you approve, items go to Recently Deleted (recoverable for 30 days).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    Task { await runCleanup() }
                } label: {
                    Text("Delete \(total) items")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                Button {
                    appModel.phase = .triage
                } label: {
                    Text("Back")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func runningView(total: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Deleting \(total) items…")
                .font(.headline)
            Text("Approve the iOS confirmation dialog to continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func summaryView(total: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: lastError == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(lastError == nil ? .green : .orange)
                .padding(.top, 24)
            Text(lastError == nil ? "Done" : "Cleanup failed")
                .font(.title2.bold())
            VStack(spacing: 4) {
                Text(lastError == nil ? "\(succeeded) deleted" : (lastError ?? ""))
                    .font(.body)
                    .foregroundStyle(lastError == nil ? Color.primary : Color.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if lastError == nil, bytesFreed > 0 {
                    Text("Freed \(FileSize.format(bytesFreed))")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                }
            }
            Spacer()
            Button {
                appModel.resetLocalTriage()
                appModel.phase = .idle
            } label: {
                Text("Back to library")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func runCleanup() async {
        isRunning = true
        hasStarted = true
        let assets = appModel.localDeleteQueue
        // Capture sizes BEFORE deletion — PHAssetResource lookup after
        // delete returns nothing.
        let totalBytes = assets.reduce(into: Int64(0)) { $0 += $1.fileSizeBytes }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            succeeded = assets.count
            bytesFreed = totalBytes
            lastError = nil
            // Mac-style empty-trash crumple. Fires only on actual
            // success so a user-cancelled iOS confirmation dialog
            // stays silent.
            SoundEffects.playCleanupTrash()
        } catch {
            lastError = error.localizedDescription
        }
        isRunning = false
    }
}
