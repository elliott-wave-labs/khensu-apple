// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Reverses a video on device, one second at a time so memory stays small. Audio is dropped.
enum ClipReverse {
    static func reverse(_ url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try await run(url) }.value
    }

    private static func run(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompositionExport.ExportError.failed("That clip has no video to reverse.")
        }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = Double(try await track.load(.nominalFrameRate)).clamped(to: 15...60)

        let out = MediaImport.mediaDir.appendingPathComponent("reversed-\(url.deletingPathExtension().lastPathComponent).mov")
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc,
                                                                           AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw CompositionExport.ExportError.failed(writer.error?.localizedDescription ?? "Reverse failed.") }
        writer.startSession(atSourceTime: .zero)

        var frameIndex: Int64 = 0
        var chunkEnd = duration
        while chunkEnd > 0.0001 {
            let chunkStart = max(0, chunkEnd - 1)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: chunkStart, preferredTimescale: 600),
                                           end: CMTime(seconds: chunkEnd, preferredTimescale: 600))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
            reader.add(output)
            reader.startReading()
            var frames: [CVPixelBuffer] = []
            while let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if pts >= chunkStart - 0.0001, pts < chunkEnd - 0.0001, let pb = CMSampleBufferGetImageBuffer(sample) { frames.append(pb) }
            }
            for pb in frames.reversed() {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                adaptor.append(pb, withPresentationTime: CMTime(value: frameIndex, timescale: CMTimeScale(fps.rounded())))
                frameIndex += 1
            }
            chunkEnd = chunkStart
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw CompositionExport.ExportError.failed(writer.error?.localizedDescription ?? "Reverse failed.") }
        return out
    }
}

/// Lifts the subject out of a photo as a transparent PNG sticker (Vision foreground instance mask).
enum CutoutSticker {
    enum CutoutError: Error, LocalizedError {
        case none, failed
        var errorDescription: String? { self == .none ? "No subject was found in that photo on this device." : "The cutout could not be made." }
    }

    static func make(from url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try run(url) }.value
    }

    private static func run(_ url: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { throw CutoutError.failed }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else { throw CutoutError.none }
        let masked = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
        let ci = CIImage(cvPixelBuffer: masked)
        guard let out = CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw CutoutError.failed }
        let dest = MediaImport.mediaDir.appendingPathComponent("cutout-\(UUID().uuidString.prefix(8)).png")
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CutoutError.failed }
        CGImageDestinationAddImage(d, out, nil)
        guard CGImageDestinationFinalize(d) else { throw CutoutError.failed }
        return dest
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
