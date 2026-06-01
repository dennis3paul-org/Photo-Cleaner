import Photos

/// A pre-defined filter on the user's PhotoKit library. Each scope knows how to
/// build a `PHFetchResult` of the assets it covers; the Pick Batch screen
/// previews counts and the Triage screen will consume the same fetch.
enum BatchScope: String, CaseIterable, Identifiable, Hashable {
    case screenshots
    case videos
    case favorites
    case recents
    case selfies
    case allPhotos

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .screenshots: return "📸"
        case .videos:      return "▶"
        case .favorites:   return "❤️"
        case .recents:     return "📅"
        case .selfies:     return "🤳"
        case .allPhotos:   return "📷"
        }
    }

    var title: String {
        switch self {
        case .screenshots: return "Screenshots"
        case .videos:      return "Videos"
        case .favorites:   return "Favorites"
        case .recents:     return "Last 30 Days"
        case .selfies:     return "Selfies"
        case .allPhotos:   return "All Photos"
        }
    }

    var subtitle: String {
        switch self {
        case .screenshots: return "Likely trash"
        case .videos:      return "Biggest by storage"
        case .favorites:   return "Marked with ❤️"
        case .recents:     return "Taken recently"
        case .selfies:     return "Front-camera shots"
        case .allPhotos:   return "Every photo"
        }
    }

    func fetchAssets() -> PHFetchResult<PHAsset> {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        switch self {
        case .allPhotos:
            return PHAsset.fetchAssets(with: .image, options: opts)

        case .videos:
            return PHAsset.fetchAssets(with: .video, options: opts)

        case .screenshots:
            opts.predicate = NSPredicate(
                format: "(mediaSubtypes & %d) != 0",
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
            return PHAsset.fetchAssets(with: .image, options: opts)

        case .favorites:
            opts.predicate = NSPredicate(format: "isFavorite == YES")
            return PHAsset.fetchAssets(with: opts)

        case .recents:
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            opts.predicate = NSPredicate(format: "creationDate > %@", cutoff as NSDate)
            return PHAsset.fetchAssets(with: opts)

        case .selfies:
            let albums = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: .smartAlbumSelfPortraits,
                options: nil
            )
            guard let collection = albums.firstObject else {
                opts.predicate = NSPredicate(value: false)
                return PHAsset.fetchAssets(with: opts)
            }
            return PHAsset.fetchAssets(in: collection, options: opts)
        }
    }
}
