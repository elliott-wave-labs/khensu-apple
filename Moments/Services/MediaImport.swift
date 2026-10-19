// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import Foundation
import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum MediaImport {
    /// Persistent on-device media folder (Application Support). Clips must survive relaunch.
    static var mediaDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nu.moments/Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func clip(from item: PhotosPickerItem) async throws -> MomentClip {
        guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
            if let data = try await item.loadTransferable(type: Data.self) {
                let url = MediaImport.mediaDir
                    .appendingPathComponent("photo-\(UUID().uuidString).jpg")
                try data.write(to: url)
                return MomentClip(url: url, duration: 2.4, isPhoto: true)
            }
            throw ImportError.unsupported
        }
        let asset = AVURLAsset(url: movie.url)
        let duration = try await asset.load(.duration).seconds
        return MomentClip(url: movie.url, duration: duration, isPhoto: false)
    }

    static func music(from url: URL) -> URL {
        let dest = MediaImport.mediaDir
            .appendingPathComponent("music-\(UUID().uuidString).\(url.pathExtension)")
        try? FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    enum ImportError: Error, LocalizedError {
        case unsupported
        var errorDescription: String? { "That file could not be imported on this device." }
    }
}

struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = MediaImport.mediaDir
                .appendingPathComponent("clip-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
        FileRepresentation(contentType: .mpeg4Movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = MediaImport.mediaDir
                .appendingPathComponent("clip-\(UUID().uuidString).mp4")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
        FileRepresentation(contentType: .quickTimeMovie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = MediaImport.mediaDir
                .appendingPathComponent("clip-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}
