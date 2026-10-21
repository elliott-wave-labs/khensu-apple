// SPDX-License-Identifier: AGPL-3.0-only

import CoreLocation
import Foundation
import Photos

/// Suggested moments from the photo library. Runs only when the person taps For You,
/// reads only what is already on the device (never downloads from iCloud), and keeps nothing until they open one.
enum ForYou {
    struct Suggestion: Identifiable, Sendable {
        let id: String
        let title: String
        let subtitle: String
        let assetIDs: [String]
        let templateID: String
    }

    enum ForYouError: Error, LocalizedError {
        case denied, empty
        var errorDescription: String? {
            switch self {
            case .denied: "Photo library access is off. You can still add photos and video by hand."
            case .empty: "Nothing to suggest yet. Shoot a few photos or videos and try again."
            }
        }
    }

    static func suggestions() async throws -> [Suggestion] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw ForYouError.denied }
        return try await Task.detached(priority: .userInitiated) { try build() }.value
    }

    private static func build() throws -> [Suggestion] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "creationDate > %@", Date().addingTimeInterval(-120 * 86_400) as NSDate)
        opts.fetchLimit = 1500
        let fetch = PHAsset.fetchAssets(with: opts)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in if a.mediaType == .image || a.mediaType == .video { assets.append(a) } }
        guard !assets.isEmpty else { throw ForYouError.empty }

        // Group by time: a new moment starts after a gap of more than 8 hours.
        var groups: [[PHAsset]] = []
        for a in assets {
            if let last = groups.last?.last, let d0 = last.creationDate, let d1 = a.creationDate, d0.timeIntervalSince(d1) < 8 * 3600 {
                groups[groups.count - 1].append(a)
            } else {
                groups.append([a])
            }
        }
        let df = DateFormatter()
        df.dateFormat = "EEEE d MMMM"
        var out: [Suggestion] = []
        for g in groups where g.count >= 4 {
            let picks = pick(g, max: 12)
            let date = g.last?.creationDate ?? .now
            let videos = g.filter { $0.mediaType == .video }.count
            let far = isAway(g)
            let title = far ? "Away, \(df.string(from: date))" : Calendar.current.isDateInWeekend(date) ? "Weekend, \(df.string(from: date))" : df.string(from: date)
            out.append(Suggestion(id: picks.first?.localIdentifier ?? UUID().uuidString, title: title,
                                  subtitle: "\(g.count) items\(videos > 0 ? ", \(videos) video" : "")",
                                  assetIDs: picks.map(\.localIdentifier), templateID: far ? "postcard" : videos > 2 ? "pulse" : "photo-dump"))
            if out.count >= 8 { break }
        }
        let favs = assets.filter(\.isFavorite)
        if favs.count >= 4 {
            out.insert(Suggestion(id: "favourites", title: "Your favourites", subtitle: "\(favs.count) hearted lately",
                                  assetIDs: pick(favs, max: 12).map(\.localIdentifier), templateID: "photo-dump"), at: 0)
        }
        guard !out.isEmpty else { throw ForYouError.empty }
        return out
    }

    /// Spread picks across the group, favourites first.
    private static func pick(_ g: [PHAsset], max n: Int) -> [PHAsset] {
        let chrono = g.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        guard chrono.count > n else { return chrono }
        let favs = chrono.filter(\.isFavorite).prefix(n / 2)
        let rest = chrono.filter { !$0.isFavorite }
        let step = Double(rest.count) / Double(n - favs.count)
        let spread = (0..<(n - favs.count)).map { rest[min(rest.count - 1, Int(Double($0) * step))] }
        return (Array(favs) + spread).sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    private static func isAway(_ g: [PHAsset]) -> Bool {
        let locs = g.compactMap(\.location)
        guard let a = locs.first, let b = locs.last else { return false }
        return locs.contains { $0.distance(from: a) > 80_000 } || a.distance(from: b) > 80_000
    }

    /// Copies the chosen assets that are on this device into the media folder as clips.
    static func clips(for s: Suggestion) async -> [MomentClip] {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: s.assetIDs, options: nil)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in assets.append(a) }
        assets.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        var out: [MomentClip] = []
        for a in assets {
            let resources = PHAssetResource.assetResources(for: a)
            guard let r = resources.first(where: { $0.type == (a.mediaType == .video ? .video : .photo) }) ?? resources.first else { continue }
            let ext = (r.originalFilename as NSString).pathExtension.isEmpty ? (a.mediaType == .video ? "mov" : "jpg") : (r.originalFilename as NSString).pathExtension
            let dest = MediaImport.mediaDir.appendingPathComponent("foryou-\(UUID().uuidString.prefix(8)).\(ext)")
            let o = PHAssetResourceRequestOptions()
            o.isNetworkAccessAllowed = false
            let ok: Bool = await withCheckedContinuation { c in
                PHAssetResourceManager.default().writeData(for: r, toFile: dest, options: o) { c.resume(returning: $0 == nil) }
            }
            guard ok else { continue }
            if a.mediaType == .video {
                out.append(MomentClip(url: dest, duration: a.duration, isPhoto: false, outDuration: min(a.duration, 2.4)))
            } else {
                out.append(MomentClip(url: dest, duration: 2.4, isPhoto: true))
            }
        }
        return out
    }
}
