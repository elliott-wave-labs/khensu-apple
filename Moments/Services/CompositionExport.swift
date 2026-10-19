// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Builds an AVFoundation composition from a project and exports HEVC (or H.264 fallback).
enum CompositionExport {
    enum ExportError: Error, LocalizedError {
        case empty
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .empty: "Add at least one clip."
            case .failed(let s): s
            }
        }
    }

    @MainActor
    static func export(_ project: MomentProject) async throws -> URL {
        try await export(ExportSnapshot(project: project))
    }

    /// Composition + video composition for preview and export (1080x1920).
    static func makeComposition(_ project: ExportSnapshot) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        guard !project.clips.isEmpty else { throw ExportError.empty }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.failed("Could not create a video track.")
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        let size = CGSize(width: 1080, height: 1920)
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for clip in project.clips {
            let asset = AVURLAsset(url: clip.url)
            if clip.isPhoto {
                let still = try await stillSegment(url: clip.url, duration: clip.outDuration, size: size)
                let assetTrack = try await still.loadTracks(withMediaType: .video).first
                guard let assetTrack else { continue }
                let timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: clip.outDuration, preferredTimescale: 600))
                try videoTrack.insertTimeRange(timeRange, of: assetTrack, at: cursor)
                let instr = AVMutableVideoCompositionInstruction()
                instr.timeRange = CMTimeRange(start: cursor, duration: timeRange.duration)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                layer.setTransform(fitTransform(for: assetTrack, canvas: size), at: cursor)
                instr.layerInstructions = [layer]
                instructions.append(instr)
                cursor = cursor + timeRange.duration
                continue
            }

            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let src = tracks.first else { continue }
            let start = CMTime(seconds: clip.inPoint, preferredTimescale: 600)
            let dur = CMTime(seconds: min(clip.outDuration, max(0.1, clip.duration - clip.inPoint)), preferredTimescale: 600)
            let range = CMTimeRange(start: start, duration: dur)
            try videoTrack.insertTimeRange(range, of: src, at: cursor)

            if let aTrack = audioTrack, let srcA = try await asset.loadTracks(withMediaType: .audio).first {
                try? aTrack.insertTimeRange(range, of: srcA, at: cursor)
            }

            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: cursor, duration: dur)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(fitTransform(for: src, canvas: size), at: cursor)
            instr.layerInstructions = [layer]
            instructions.append(instr)
            cursor = cursor + dur
        }

        if let music = project.musicURL, let aTrack = audioTrack {
            let song = AVURLAsset(url: music)
            if let src = try await song.loadTracks(withMediaType: .audio).first {
                let range = CMTimeRange(start: .zero, duration: cursor)
                try? aTrack.insertTimeRange(range, of: src, at: .zero)
            }
        }

        let videoComp = AVMutableVideoComposition()
        videoComp.instructions = instructions
        videoComp.renderSize = size
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        return (composition, videoComp)
    }

    static func export(_ project: ExportSnapshot) async throws -> URL {
        let (composition, videoComp) = try await makeComposition(project)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("nu-moments-\(project.id.uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failed("Export session unavailable.")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = videoComp
        export.metadata = [
            AVMutableMetadataItem().then {
                $0.identifier = .commonIdentifierTitle
                $0.value = project.title as NSString
            },
        ]
        await export.export()
        if export.status == .completed { return out }
        throw ExportError.failed(export.error?.localizedDescription ?? "Export failed.")
    }

    private static func fitTransform(for track: AVAssetTrack, canvas: CGSize) -> CGAffineTransform {
        let natural = track.naturalSize.applying(track.preferredTransform)
        let w = abs(natural.width)
        let h = abs(natural.height)
        guard w > 1, h > 1 else { return .identity }
        let scale = max(canvas.width / w, canvas.height / h)
        var t = track.preferredTransform
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let sw = w * scale
        let sh = h * scale
        t = t.concatenating(CGAffineTransform(translationX: (canvas.width - sw) / 2, y: (canvas.height - sh) / 2))
        return t
    }

    private static func stillSegment(url: URL, duration: TimeInterval, size: CGSize) async throws -> AVAsset {
        #if canImport(UIKit)
        guard let image = UIImage(contentsOfFile: url.path) else {
            throw ExportError.failed("Could not read photo.")
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        let framed = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let aspect = image.size.width / max(image.size.height, 1)
            var draw = CGRect(origin: .zero, size: size)
            if aspect > size.width / size.height {
                draw.size.width = size.height * aspect
                draw.origin.x = (size.width - draw.size.width) / 2
            } else {
                draw.size.height = size.width / aspect
                draw.origin.y = (size.height - draw.size.height) / 2
            }
            image.draw(in: draw)
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).mp4")
        try await writeStillVideo(image: framed, duration: duration, to: tmp, size: size)
        return AVURLAsset(url: tmp)
        #else
        throw ExportError.failed("Photo stills need UIKit on this build.")
        #endif
    }

    #if canImport(UIKit)
    private static func writeStillVideo(image: UIImage, duration: TimeInterval, to url: URL, size: CGSize) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        guard let buffer = pixelBuffer(from: image, size: size) else {
            throw ExportError.failed("Pixel buffer failed.")
        }
        let frameDuration = CMTime(value: 1, timescale: 30)
        var frame: Int64 = 0
        let total = Int64(duration * 30)
        while frame < total {
            if input.isReadyForMoreMediaData {
                adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(frame)))
                frame += 1
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.failed(writer.error?.localizedDescription ?? "Still encode failed.")
        }
    }

    private static func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB, attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ), let cg = image.cgImage else { return nil }
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        return buffer
    }
    #endif
}

private extension AVMutableMetadataItem {
    func then(_ block: (AVMutableMetadataItem) -> Void) -> AVMutableMetadataItem {
        block(self)
        return self
    }
}
