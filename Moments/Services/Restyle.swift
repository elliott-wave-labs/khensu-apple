// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// Generated restyles of a photo with Apple's Image Playground model on this device.
/// Only the on-device styles are offered; the external (ChatGPT) provider never is.
enum Restyle {
    enum Style: String, CaseIterable, Identifiable, Sendable {
        case animation, illustration, sketch
        var id: String { rawValue }
        var label: String { switch self { case .animation: "Animation"; case .illustration: "Illustration"; case .sketch: "Sketch" } }
        #if canImport(ImagePlayground)
        var playground: ImagePlaygroundStyle {
            switch self { case .animation: .animation; case .illustration: .illustration; case .sketch: .sketch }
        }
        #endif
    }

    enum RestyleError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    static func restyle(photo url: URL, style: Style, prompt: String) async throws -> URL {
        #if canImport(ImagePlayground)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else {
            throw RestyleError.message("That photo could not be read.")
        }
        do {
            let creator = try await ImageCreator()
            guard creator.availableStyles.contains(style.playground), style.playground != .externalProvider else {
                throw RestyleError.message("The \(style.label) style isn't available on this device yet.")
            }
            var concepts: [ImagePlaygroundConcept] = [.image(cg)]
            let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { concepts.append(.text(p)) }
            for try await created in creator.images(for: concepts, style: style.playground, limit: 1) {
                let dest = MediaImport.mediaDir.appendingPathComponent("restyled-\(style.rawValue)-\(UUID().uuidString.prefix(6)).png")
                guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else { break }
                CGImageDestinationAddImage(d, created.cgImage, nil)
                guard CGImageDestinationFinalize(d) else { break }
                return dest
            }
            throw RestyleError.message("No image came back. Try again or change the words.")
        } catch let e as ImageCreator.Error {
            switch e {
            case .notSupported: throw RestyleError.message("Restyle needs a device with Apple Intelligence (iPhone 15 Pro or later, or an M-series iPad or Mac).")
            case .unavailable: throw RestyleError.message("Image Playground isn't ready. Turn on Apple Intelligence in Settings and let its models finish downloading.")
            case .faceInImageTooSmall: throw RestyleError.message("The face in that photo is too small to restyle. Try a closer photo.")
            case .unsupportedLanguage: throw RestyleError.message("Those words are in a language Image Playground doesn't support yet.")
            case .unsupportedInputImage: throw RestyleError.message("Image Playground can't use that photo.")
            case .backgroundCreationForbidden: throw RestyleError.message("Keep nu.moments open while the restyle finishes.")
            case .creationCancelled: throw RestyleError.message("Restyle was cancelled.")
            default: throw RestyleError.message("Image Playground couldn't restyle that photo.")
            }
        }
        #else
        throw RestyleError.message("Restyle isn't available on this device.")
        #endif
    }
}
