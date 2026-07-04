import Photos
import SwiftUI

/// Wraps PhotoKit: authorization, library tally, and live change observation.
@MainActor
final class PhotoLibraryService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var photoCount: Int = 0
    @Published private(set) var videoCount: Int = 0
    @Published private(set) var totalCount: Int = 0

    override init() {
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        PHPhotoLibrary.shared().register(self)
        if isAuthorized {
            refreshTally()
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        self.authorizationStatus = status
        if isAuthorized {
            refreshTally()
        }
    }

    func refreshTally() {
        // PhotoKit fetches are thread-safe; run them off the main actor.
        // The old version did three synchronous full-library fetches on
        // main — a visible hitch at launch and again on every library
        // change notification.
        Task.detached(priority: .userInitiated) {
            let opts = PHFetchOptions()
            let photos = PHAsset.fetchAssets(with: .image, options: opts).count
            let videos = PHAsset.fetchAssets(with: .video, options: opts).count
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.photoCount = photos
                self.videoCount = videos
                self.totalCount = photos + videos
            }
        }
    }
}

extension PhotoLibraryService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.refreshTally()
        }
    }
}
