import CoreLocation
import Foundation
import Photos

extension MemoryProbe.PhotoSource {
    /// PhotoKit, read only: the creation date, the location and the favorite flag of the first `limit` assets of the
    /// window. No resources, originals, thumbnails, names or identifiers are touched, and nothing prompts for access.
    public static let live = MemoryProbe.PhotoSource(
        access: {
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized: .authorized
            case .limited: .limited
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            @unknown default: .denied
            }
        },
        sample: { interval, limit in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            // The date predicate also excludes assets without a creationDate: they cannot belong to a dated window.
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", interval.start as NSDate, interval.end as NSDate)
            // No fetchLimit: it would cap `count` as well, and the visible total is the point. Assets load lazily.
            let found = PHAsset.fetchAssets(with: options)
            let sampled = min(found.count, limit)
            var located = 0, favorites = 0
            for index in 0..<sampled {
                let asset = found.object(at: index)
                if let coordinate = asset.location?.coordinate, CLLocationCoordinate2DIsValid(coordinate) { located += 1 }
                if asset.isFavorite { favorites += 1 }
            }
            return MemoryProbe.PhotoSample(visibleTotal: found.count, sampled: sampled, withValidLocation: located, favorites: favorites)
        })
}
