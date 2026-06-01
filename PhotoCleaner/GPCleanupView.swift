import SwiftUI

/// Runs the delete queue against Google's internal trash RPC. Rendered as an
/// overlay on top of GooglePhotosView so the WebView's authenticated session
/// (WIZ tokens, cookies) stays live underneath.
struct GPCleanupView: View {
    @EnvironmentObject var appModel: AppModel

    /// Bulk delete: hand the whole queue to JS, which runs N parallel workers
    /// against the trash RPC. Returns (succeeded count, failed-IDs list).
    let bulkDeleteAction: ([GPPhoto], Int) async throws -> (succeeded: Int, failedIds: [String])

    /// Snapshot of progress for live polling during a bulk delete.
    let progressAction: () async -> GooglePhotosWebController.BulkProgress

    /// After cleanup, hide deleted tiles from the WebView DOM (preserves scroll).
    let hideDeletedAction: ([String]) async -> Void

    /// Soft reload the GP page once the bulk RPC has *actually* completed,
    /// so the gaps left by absolutely-positioned tiles get cleaned up. The
    /// scroll position survives via sessionStorage + the scroll-restore
    /// userscript that runs on every page load. Only used by the XwAOJf
    /// fallback path; the native-UI path doesn't need it.
    let reloadAction: () async -> Void

    /// Primary delete path: drive GP's own trash UI. Takes the list of
    /// "keep" photo IDs to deselect first. Returns nil on success or an
    /// error string for the fallback to consume.
    let nativeDeleteAction: ([String]) async -> String?

    /// Diagnose helper for the cleanup flow (kept for parity with the old API).
    let diagnoseAction: () async -> String

    @State private var cursor: Int = 0
    @State private var succeeded: Int = 0
    @State private var failed: [String] = []
    @State private var isRunning: Bool = false
    @State private var hasStarted: Bool = false
    @State private var lastError: String?
    @State private var diagnostics: String?
    @State private var phase: String = "init"
    @State private var durationMs: Int = 0
    @State private var callCount: Int = 0
    @State private var totalCallMs: Int = 0
    @State private var minCallMs: Int = 0
    @State private var maxCallMs: Int = 0

    /// Dropped to 4 after measurement showed Google throttles per-RPC time
    /// progressively as concurrency rises (min 3.7s at low load, 21.5s at
    /// max load with concurrency=10). A smaller burst should keep each
    /// individual RPC fast and net out faster wall-clock.
    private let concurrency = 4

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task {
            // Auto-run cleanup on appear — no separate confirmation step.
            // Items go to GP trash (60 days recoverable) so the swipe is the
            // confirmation.
            guard !hasStarted else { return }
            await runCleanup()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                appModel.phase = .googlePhotos
                appModel.resetGPTriage()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Library")
                }
                .font(.body.weight(.medium))
            }
            .disabled(isRunning)
            .opacity(isRunning ? 0.4 : 1)
            Spacer()
            VStack(spacing: 1) {
                Text("Cleanup")
                    .font(.headline)
                Text("\(cursor) / \(appModel.gpDeleteQueue.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Library")
            }
            .font(.body.weight(.medium))
            .opacity(0)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let total = appModel.gpDeleteQueue.count
        if !hasStarted || isRunning {
            runningView(total: total)
        } else {
            summaryView(total: total)
        }
    }

    private func runningView(total: Int) -> some View {
        // Note: we deliberately don't show `lastError` during running. The
        // batchexecute attempt can fail with an expected HTTP 400 while the
        // parallel-worker fallback succeeds — surfacing the transient error
        // is just noise. Errors only show on the summary if any photo
        // actually failed.
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: Double(cursor), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .tint(.red)
                .padding(.horizontal, 32)

            VStack(spacing: 4) {
                Text("Deleting \(cursor) / \(total)")
                    .font(.title3.bold())
                    .monospacedDigit()
                Text(phaseDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var phaseDescription: String {
        switch phase {
        case "init":         return "Starting…"
        case "prefetch":     return "Looking up action tokens…"
        case "bulk":         return "Bulk delete (one request)…"
        case "parallel":     return "Retrying remaining individually…"
        case "done":         return durationMs > 0 ? String(format: "Done in %.1fs", Double(durationMs) / 1000) : "Done"
        default:             return phase
        }
    }

    private func summaryView(total: Int) -> some View {
        // Sum the sizes of photos that actually deleted (i.e. weren't in
        // the failed list) so the "freed" number is honest.
        let failedSet = Set(failed)
        let freedBytes = appModel.gpDeleteQueue
            .filter { !failedSet.contains($0.id) }
            .reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        return VStack(spacing: 16) {
            Image(systemName: failed.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(failed.isEmpty ? .green : .orange)
                .padding(.top, 24)
            Text(failed.isEmpty ? "Done" : "Finished with errors")
                .font(.title2.bold())
            VStack(spacing: 4) {
                Text("\(succeeded) deleted")
                if freedBytes > 0 {
                    Text("Freed \(FileSize.format(freedBytes))")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                }
                if !failed.isEmpty {
                    Text("\(failed.count) failed")
                        .foregroundStyle(.orange)
                }
                if durationMs > 0 {
                    Text(String(format: "in %.1fs", Double(durationMs) / 1000))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if callCount > 0 {
                    let avg = totalCallMs / max(callCount, 1)
                    Text("avg \(avg)ms · min \(minCallMs)ms · max \(maxCallMs)ms per RPC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.body)

            // Only show the error blob when photos actually failed to delete.
            // Otherwise transient batch-attempt errors (e.g. HTTP 400 that
            // was fully recovered by the parallel fallback) would look like
            // an alarm to the user.
            if !failed.isEmpty, let err = lastError {
                ScrollView {
                    Text(err)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 220)
                .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)

                Button {
                    UIPasteboard.general.string = err
                } label: {
                    Label("Copy error", systemImage: "doc.on.doc")
                        .font(.caption)
                }
            }

            Spacer()
            Button {
                appModel.resetGPTriage()
                appModel.phase = .googlePhotos
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

    /// Cleanup: optimistic "Done" UI + native-GP-UI delete (primary path),
    /// with XwAOJf RPC as a safety-net fallback if GP's UI selectors aren't
    /// found. GP's own trash flow updates GP's internal state and reflows
    /// the grid in place — no manual reload + scroll restore required, and
    /// no gaps left behind.
    private func runCleanup() async {
        hasStarted = true
        isRunning = false   // skip the loading view — we're optimistic
        let queue = appModel.gpDeleteQueue
        let keepIds = appModel.gpKeepIds
        let startTime = Date()

        // Optimistic state — claim success instantly.
        succeeded = queue.count
        cursor = queue.count
        failed = []
        durationMs = 0
        phase = "done"

        // Primary: drive GP's own trash UI. If it works, the deletion AND
        // the in-place grid refresh both happen natively.
        let nativeError = await nativeDeleteAction(keepIds)
        if nativeError == nil {
            durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            phase = "done"
            SoundEffects.playCleanupTrash()
            return
        }

        // Fallback: XwAOJf bulk RPC + DOM hide + soft reload. Used when GP
        // rotated selectors or the confirm dialog didn't appear.
        lastError = "GP UI: \(nativeError ?? "?") — using XwAOJf fallback"

        // Optimistic DOM hide — tiles disappear right away.
        Task { await hideDeletedAction(queue.map(\.id)) }

        do {
            let result = try await bulkDeleteAction(queue, concurrency)
            succeeded = result.succeeded
            failed = result.failedIds
            cursor = queue.count
            let final = await progressAction()
            durationMs = final.durationMs
            phase = final.phase
            callCount = final.callCount
            totalCallMs = final.totalCallMs
            minCallMs = final.minCallMs
            maxCallMs = final.maxCallMs

            // If XwAOJf finished but didn't actually trash anything, pull
            // the JS-side lastError (most useful debug info — EzkLib
            // date-search failures, missing action tokens, etc) and
            // replace our pre-fallback message with it.
            if result.succeeded == 0, !final.lastError.isEmpty {
                lastError = "XwAOJf: \(final.lastError)"
            }

            // Mac-trash crumple if at least one photo actually
            // trashed — matches the local cleanup flow.
            if result.succeeded > 0 {
                SoundEffects.playCleanupTrash()
            }

            // Note: we intentionally do NOT reload the GP WebView after
            // the XwAOJf bulk RPC anymore. The reload took 5-10s and was
            // the slowest part of the user's cleanup experience. The
            // visible tradeoff: GP uses absolute-positioned grid cells,
            // so removing tiles via hideDeletedAction leaves gaps until
            // the next full GP navigation. That's an acceptable cost
            // for instant return-to-library — users naturally re-scroll
            // or revisit, which causes GP to reflow on its own.
        } catch {
            lastError = "Both paths failed. GP UI: \(nativeError ?? "?"). RPC: \(error.localizedDescription)"
            failed = queue.map(\.id)
            succeeded = 0
        }
    }
}
