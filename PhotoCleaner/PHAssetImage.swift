import Photos
import SwiftUI
import UIKit

/// Loads a PHAsset's image asynchronously via PHImageManager and renders it
/// with aspectRatio(.fit) so landscape and portrait photos both show in full.
struct PHAssetImage: View {
    let asset: PHAsset
    let targetSize: CGSize

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Color.gray.opacity(0.18)
                    ProgressView().controlSize(.regular)
                }
            }
        }
        .task(id: asset.localIdentifier) {
            await load()
        }
    }

    private func load() async {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic   // progressive: thumbnail first, full quality after
        opts.isNetworkAccessAllowed = true   // iCloud-stored originals
        opts.resizeMode = .exact

        let scale = await MainActor.run { UIScreen.main.scale }
        let pixelSize = CGSize(
            width: max(targetSize.width * scale, 256),
            height: max(targetSize.height * scale, 256)
        )

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: pixelSize,
            contentMode: .aspectFit,
            options: opts
        ) { result, _ in
            guard let result else { return }
            Task { @MainActor in
                self.image = result
            }
        }
    }
}

/// Convenience label for local assets — mirrors the GP "Type - Orientation -
/// Date" format so the card pill reads consistently between sources.
extension PHAsset {
    var triageLabel: String {
        let type = mediaType == .video ? "Video" : "Photo"
        let orient = pixelWidth >= pixelHeight ? "Landscape" : "Portrait"
        let dateStr: String
        if let creationDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            dateStr = formatter.string(from: creationDate)
        } else {
            dateStr = "Unknown date"
        }
        return "\(type) - \(orient) - \(dateStr)"
    }

    /// Underlying file size in bytes, summed across all asset resources
    /// (e.g. Live Photos = still + motion). Returns 0 if PhotoKit doesn't
    /// expose it (rare on simulator media). Reads the private but
    /// long-stable `fileSize` key on `PHAssetResource`.
    var fileSizeBytes: Int64 {
        let resources = PHAssetResource.assetResources(for: self)
        var total: Int64 = 0
        for res in resources {
            if let n = res.value(forKey: "fileSize") as? NSNumber {
                total += n.int64Value
            }
        }
        return total
    }
}

/// Shared byte formatter — used by both local + GP UI for consistent
/// "12.4 MB" style display.
enum FileSize {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }()
    static func format(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        return formatter.string(fromByteCount: bytes)
    }
}
