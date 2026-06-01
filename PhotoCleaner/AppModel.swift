import Foundation
import Photos
import SwiftUI

/// High-level state machine. Each phase corresponds to one screen.
///
///   permission → idle → pickBatch → triage → cleanup → done
///
/// `permission` is implicit and lives on the auth status of `PhotoLibraryService`;
/// `AppPhase` tracks only the post-permission flow.
enum AppPhase: Equatable {
    case idle
    case pickBatch
    case triage
    case cleanup
    case done
    case googlePhotos
    case googleSwipe
    case googleCleanup
}

/// One decision the user made during triage. We keep them in order so undo
/// can pop the last one and reverse its effect.
struct LocalDecisionRecord {
    let asset: PHAsset
    let decision: SwipeDecision
}

struct GPDecisionRecord {
    let photo: GPPhoto
    let decision: SwipeDecision
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var selectedScope: BatchScope?

    /// App-lifetime GP WebView controller. Persisting this outside of the
    /// per-view @StateObject means the underlying WKWebView (with its loaded
    /// page, cookies, scroll position, and any selections) survives across
    /// navigations to and from GooglePhotosView. Re-entry is essentially
    /// instant instead of triggering a full page reload.
    let gpWebController = GooglePhotosWebController()

    // Local PhotoKit triage state.
    @Published var localAssets: [PHAsset] = []
    @Published var localCursor: Int = 0
    @Published var localDeleteQueue: [PHAsset] = []
    @Published var localKeepCount: Int = 0
    @Published var localHistory: [LocalDecisionRecord] = []

    func startLocalTriage(_ assets: [PHAsset]) {
        localAssets = assets
        localCursor = 0
        localDeleteQueue = []
        localKeepCount = 0
        localHistory = []
        phase = .triage
    }

    func resetLocalTriage() {
        localAssets = []
        localCursor = 0
        localDeleteQueue = []
        localKeepCount = 0
        localHistory = []
        selectedScope = nil
    }

    /// Reverse the most recent local decision: pull it off history, take it
    /// off the delete queue / keep count, and step the cursor back so the
    /// card returns. Returns true if anything was undone.
    @discardableResult
    func undoLocal() -> Bool {
        guard let last = localHistory.popLast() else { return false }
        switch last.decision {
        case .delete:
            if let idx = localDeleteQueue.lastIndex(where: { $0.localIdentifier == last.asset.localIdentifier }) {
                localDeleteQueue.remove(at: idx)
            }
        case .keep:
            localKeepCount = max(localKeepCount - 1, 0)
        }
        withAnimation(.spring(duration: 0.25)) {
            localCursor = max(localCursor - 1, 0)
        }
        return true
    }

    // Google Photos triage state.
    @Published var gpPhotos: [GPPhoto] = []
    @Published var gpCursor: Int = 0
    @Published var gpDeleteQueue: [GPPhoto] = []
    @Published var gpKeepCount: Int = 0
    @Published var gpHistory: [GPDecisionRecord] = []

    func startGPTriage(_ photos: [GPPhoto]) {
        gpPhotos = photos
        gpCursor = 0
        gpDeleteQueue = []
        gpKeepCount = 0
        gpHistory = []
        phase = .googleSwipe
    }

    func resetGPTriage() {
        gpPhotos = []
        gpCursor = 0
        gpDeleteQueue = []
        gpKeepCount = 0
        gpHistory = []
    }

    /// IDs of the photos the user marked as "keep" — derived from the set
    /// difference of all triaged photos and the delete queue. Used by the
    /// GP-native trash workflow to deselect them before triggering the
    /// trash button.
    var gpKeepIds: [String] {
        let deleteSet = Set(gpDeleteQueue.map(\.id))
        return gpPhotos.filter { !deleteSet.contains($0.id) }.map(\.id)
    }

    /// Reverse the most recent GP decision.
    @discardableResult
    func undoGP() -> Bool {
        guard let last = gpHistory.popLast() else { return false }
        switch last.decision {
        case .delete:
            if let idx = gpDeleteQueue.lastIndex(where: { $0.id == last.photo.id }) {
                gpDeleteQueue.remove(at: idx)
            }
        case .keep:
            gpKeepCount = max(gpKeepCount - 1, 0)
        }
        withAnimation(.spring(duration: 0.25)) {
            gpCursor = max(gpCursor - 1, 0)
        }
        return true
    }
}
