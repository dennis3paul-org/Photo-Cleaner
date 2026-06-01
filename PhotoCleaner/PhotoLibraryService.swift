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
        let opts = PHFetchOptions()
        photoCount = PHAsset.fetchAssets(with: .image, options: opts).count
        videoCount = PHAsset.fetchAssets(with: .video, options: opts).count
        totalCount = PHAsset.fetchAssets(with: opts).count
    }
}

extension PhotoLibraryService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.refreshTally()
        }
    }
}
