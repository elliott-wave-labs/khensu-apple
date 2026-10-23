// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Painter styles: fast style-transfer networks trained with Create ML on public-domain paintings, run on this device.
/// A photo becomes a painted photo; a clip is painted frame by frame into a new file with the same timing.
enum PaintStyle {
    enum Style: String, CaseIterable, Identifiable, Sendable {
        case wave, starry, scream, cubist, kandinsky
        var id: String { rawValue }
        var label: String {
            switch self {
            case .wave: "The Great Wave"; case .starry: "Starry Night"; case .scream: "The Scream"; case .cubist: "Cubist"; case .kandinsky: "Kandinsky"
            }
        }
        /// The painting the network learned from.
        var after: String {
            switch self {
            case .wave: "Hokusai, The Great Wave off Kanagawa, about 1831"
            case .starry: "Van Gogh, The Starry Night, 1889"
            case .scream: "Munch, The Scream, 1893"
            case .cubist: "Juan Gris, Still Life before an Open Window, Place Ravignan, 1915"
            case .kandinsky: "Kandinsky, Composition VII, 1913"
            }
        }
        var modelName: String { "Paint-\(rawValue)" }
    }

    enum PaintError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var models: [Style: MLModel] = [:]
    }
    private static let cache = Cache()

    static func model(_ style: Style) throws -> MLModel {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let m = cache.models[style] { return m }
        guard let url = Bundle.main.url(forResource: style.modelName, withExtension: "mlmodelc") else {
            throw PaintError.message("The \(style.label) style is missing from this build.")
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU
        let m = try MLModel(contentsOf: url, configuration: cfg)
        cache.models[style] = m
        return m
    }

    /// Paints one upright image (origin at zero) and returns it at the same size.
    /// - Parameters:
    ///   - brush: 0…1. A bigger brush paints at a smaller working size, so each stroke covers more of the picture.
    ///   - strength: 0…1. Below 1 the original shows through the paint.
    static func paint(_ img: CIImage, model: MLModel, brush: Double, strength: Double, ctx: CIContext) throws -> CIImage {
        guard let (name, input) = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = input.imageConstraint,
              let outName = model.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .image })?.key
        else { throw PaintError.message("That style model has no image input.") }

        let extent = img.extent
        let long = 1280 - 768 * min(1, max(0, brush))
        let fit = long / max(extent.width, extent.height)
        var w = Int(extent.width * fit), h = Int(extent.height * fit)
        let sc = constraint.sizeConstraint
        switch sc.type {
        case .range:
            w = min(max(w, sc.pixelsWideRange.location), sc.pixelsWideRange.location + sc.pixelsWideRange.length - 1)
            h = min(max(h, sc.pixelsHighRange.location), sc.pixelsHighRange.location + sc.pixelsHighRange.length - 1)
        case .enumerated:
            if let first = sc.enumeratedImageSizes.first { w = first.pixelsWide; h = first.pixelsHigh }
        default:
            w = constraint.pixelsWide; h = constraint.pixelsHigh
        }
        // The network halves the picture several times on the way down, so keep both sides multiples of 8.
        w = max(64, w / 8 * 8); h = max(64, h / 8 * 8)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, constraint.pixelFormatType,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw PaintError.message("Not enough memory to paint.") }
        let small = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
        ctx.render(small, to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(pixelBuffer: buffer)]))
        guard let painted = result.featureValue(for: outName)?.imageBufferValue else { throw PaintError.message("The style model returned nothing.") }
        let out = CIImage(cvPixelBuffer: painted)
        let back = out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: extent.height / out.extent.height,
                                                                              kCIInputAspectRatioKey: (extent.width / out.extent.width) / (extent.height / out.extent.height)])
            .cropped(to: extent)
        guard strength < 0.999 else { return back }
        return back.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: img, kCIInputTimeKey: 1 - strength]).cropped(to: extent)
    }

    /// Paints a photo into a new JPEG in the media folder.
    static func paint(photo url: URL, style: Style, brush: Double, strength: Double) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary)
            else { throw PaintError.message("That photo could not be read.") }
            let ctx = CIContext(options: [.cacheIntermediates: false])
            let painted = try paint(CIImage(cgImage: cg), model: try model(style), brush: brush, strength: strength, ctx: ctx)
            let dest = MediaImport.mediaDir.appendingPathComponent("painted-\(style.rawValue)-\(UUID().uuidString.prefix(6)).jpg")
            try ctx.writeJPEGRepresentation(of: painted, to: dest, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
            return dest
        }.value
    }

    /// Paints the frames between `from` and `to` (seconds in the file); the rest pass through, so trims stay where they were.
    static func render(_ url: URL, style: Style, from: Double, to: Double, brush: Double, strength: Double,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try await run(url, style: style, from: from, to: to, brush: brush, strength: strength, progress: progress)
        }.value
    }

    private static func run(_ url: URL, style: Style, from: Double, to: Double, brush: Double, strength: Double,
                            progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let net = try model(style)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PaintError.message("That clip has no video to paint.")
        }
        let natural = try await track.load(.naturalSize)
        let orient = CompositionExport.orientation(try await track.load(.preferredTransform))
        let sideways = orient == .left || orient == .right || orient == .leftMirrored || orient == .rightMirrored
        let up = sideways ? CGSize(width: natural.height, height: natural.width) : natural
        let fit = min(1, 1920 / max(up.width, up.height))
        let W = Int(up.width * fit) & ~1, H = Int(up.height * fit) & ~1
        guard W >= 64, H >= 64 else { throw PaintError.message("That clip is too small to paint.") }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        let out = MediaImport.mediaDir.appendingPathComponent("painted-\(style.rawValue)-\(UUID().uuidString.prefix(6)).mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: W, AVVideoHeightKey: H])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
        ])
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw PaintError.message(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Painting failed.")
        }
        writer.startSession(atSourceTime: .zero)

        let ctx = CIContext(options: [.cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let span = max(0.01, to - from)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let t = pts.seconds
            var frame = CIImage(cvPixelBuffer: pb).oriented(orient)
            frame = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
            frame = frame.transformed(by: CGAffineTransform(scaleX: CGFloat(W) / frame.extent.width, y: CGFloat(H) / frame.extent.height))
            if t >= from - 0.0005, t <= to + 0.0005 {
                frame = try autoreleasepool { try paint(frame, model: net, brush: brush, strength: strength, ctx: ctx) }
                progress?(min(1, (t - from) / span))
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var dst: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst)
            guard let dst else { continue }
            ctx.render(frame, to: dst, bounds: CGRect(x: 0, y: 0, width: W, height: H), colorSpace: space)
            adaptor.append(dst, withPresentationTime: pts)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw PaintError.message(writer.error?.localizedDescription ?? "Painting failed.") }
        progress?(1)
        return out
    }
}
