// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreImage
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Builds an AVFoundation composition from a project and exports it.
/// Template look + transitions + burned-in captions apply in preview AND export.
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

    /// Composition + video composition + audio mix for preview and export.
    static func makeComposition(_ project: ExportSnapshot) async throws -> (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?) {
        let built = try await build(project)
        return (built.0, built.1, built.2)
    }

    static func build(_ project: ExportSnapshot) async throws -> (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?) {
        guard !project.clips.isEmpty else { throw ExportError.empty }
        let size = project.format.size
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.failed("Could not create a video track.")
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var boundaries: [(start: TimeInterval, end: TimeInterval)] = []

        for clip in project.clips {
            let segStart = cursor.seconds
            if clip.isPhoto {
                let still = try await stillSegment(url: clip.url, duration: clip.outDuration, size: size, look: project.look, accent: project)
                guard let assetTrack = try await still.loadTracks(withMediaType: .video).first else { continue }
                let range = CMTimeRange(start: .zero, duration: CMTime(seconds: clip.outDuration, preferredTimescale: 600))
                try videoTrack.insertTimeRange(range, of: assetTrack, at: cursor)
                let instr = AVMutableVideoCompositionInstruction()
                instr.timeRange = CMTimeRange(start: cursor, duration: range.duration)
                instr.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                layer.setTransform(fitTransform(for: assetTrack, canvas: size), at: cursor)
                applyTransition(layer, project.transition, at: cursor, duration: range.duration.seconds, isFirst: boundaries.isEmpty)
                instr.layerInstructions = [layer]
                instructions.append(instr)
                cursor = cursor + range.duration
                boundaries.append((segStart, cursor.seconds))
                continue
            }
            let asset = AVURLAsset(url: clip.url)
            guard let src = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let speed = max(0.25, clip.speed)
            let sourceDur = min(clip.outDuration * speed, max(0.1, clip.duration - clip.inPoint))
            let outDur = sourceDur / speed
            let start = CMTime(seconds: clip.inPoint, preferredTimescale: 600)
            let range = CMTimeRange(start: start, duration: CMTime(seconds: sourceDur, preferredTimescale: 600))
            try videoTrack.insertTimeRange(range, of: src, at: cursor)
            if speed != 1 {
                videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: CMTime(seconds: sourceDur, preferredTimescale: 600)),
                                          toDuration: CMTime(seconds: outDur, preferredTimescale: 600))
            }
            if let aTrack = audioTrack, !clip.muted, let srcA = try await asset.loadTracks(withMediaType: .audio).first {
                try? aTrack.insertTimeRange(range, of: srcA, at: cursor)
                if speed != 1 {
                    aTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: CMTime(seconds: sourceDur, preferredTimescale: 600)),
                                          toDuration: CMTime(seconds: outDur, preferredTimescale: 600))
                }
            }
            let dur = CMTime(seconds: outDur, preferredTimescale: 600)
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: cursor, duration: dur)
            instr.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(fitTransform(for: src, canvas: size), at: cursor)
            applyTransition(layer, project.transition, at: cursor, duration: outDur, isFirst: boundaries.isEmpty)
            instr.layerInstructions = [layer]
            instructions.append(instr)
            cursor = cursor + dur
            boundaries.append((segStart, cursor.seconds))
        }

        guard cursor.seconds > 0 else { throw ExportError.failed("No usable clips.") }

        if let music = project.musicURL, let mTrack = musicTrack {
            let song = AVURLAsset(url: music)
            if let src = try await song.loadTracks(withMediaType: .audio).first {
                let songDur = try await song.load(.duration)
                let use = CMTimeMinimum(cursor, songDur)
                try? mTrack.insertTimeRange(CMTimeRange(start: .zero, duration: use), of: src, at: .zero)
            }
        }

        // Audio mix: music at project volume, clip audio ducks under it.
        var audioMix: AVMutableAudioMix?
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if let mTrack = musicTrack, !mTrack.segments.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: mTrack)
            p.setVolume(Float(project.musicVolume), at: .zero)
            mixParams.append(p)
            if let aTrack = audioTrack, !aTrack.segments.isEmpty {
                let p2 = AVMutableAudioMixInputParameters(track: aTrack)
                p2.setVolume(project.musicURL == nil ? 1 : 0.55, at: .zero)
                mixParams.append(p2)
            }
            let mix = AVMutableAudioMix(); mix.inputParameters = mixParams; audioMix = mix
        }

        let videoComp: AVMutableVideoComposition
        if project.look == .natural {
            let vc = AVMutableVideoComposition()
            vc.instructions = instructions
            vc.renderSize = size
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            videoComp = vc
        } else {
            videoComp = AVMutableVideoComposition(asset: composition, applyingCIFiltersWithHandler: { request in
                var image = request.sourceImage
                // Aspect-fill into the canvas, centred (replaces the layer fit transform).
                let target = CGRect(origin: .zero, size: size)
                let iw = image.extent.width, ih = image.extent.height
                if iw > 1, ih > 1 {
                    let scale = max(size.width / iw, size.height / ih)
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    let dx = (size.width - image.extent.width) / 2 - image.extent.minX
                    let dy = (size.height - image.extent.height) / 2 - image.extent.minY
                    image = image.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: target)
                }
                image = LookFilter.apply(project.look, to: image, canvas: size)
                // Template transition darkening at segment joins (handler path).
                let t = request.compositionTime.seconds
                let f = transitionFactor(project.transition, at: t, boundaries: boundaries)
                if f < 0.999 {
                    if let exp = CIFilter(name: "CIExposureAdjust") {
                        exp.setValue(image, forKey: kCIInputImageKey)
                        exp.setValue(log2(max(f, 0.05)), forKey: "inputEV")
                        if let out = exp.outputImage { image = out.cropped(to: target) }
                    }
                }
                request.finish(with: image, context: nil)
            })
            videoComp.renderSize = size
            videoComp.frameDuration = CMTime(value: 1, timescale: 30)
            // Keep clip ordering/timing; instructions are timing-only here (no layer transforms).
            videoComp.instructions = instructions.map { old in
                let i = AVMutableVideoCompositionInstruction()
                i.timeRange = old.timeRange
                i.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                return i
            }
        }

        if !project.captions.isEmpty {
            let (parent, vLayer) = captionLayers(size: size, captions: project.captions, accent: project)
            videoComp.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: vLayer, in: parent)
        }
        return (composition, videoComp, audioMix)
    }

    private static func applyTransition(_ layer: AVMutableVideoCompositionLayerInstruction, _ tr: MomentTransition, at start: CMTime, duration: TimeInterval, isFirst: Bool) {
        let fade = CMTime(seconds: min(0.28, duration / 3), preferredTimescale: 600)
        switch tr {
        case .cut: break
        case .fade, .dip:
            if !isFirst { layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: CMTimeRange(start: start, duration: fade)) }
            layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: CMTimeRange(start: start + CMTime(seconds: duration, preferredTimescale: 600) - fade, duration: fade))
        }
    }

    private static func transitionFactor(_ tr: MomentTransition, at t: TimeInterval, boundaries: [(start: TimeInterval, end: TimeInterval)]) -> Double {
        guard tr != .cut else { return 1 }
        var f = 1.0
        for b in boundaries {
            if t - b.start < 0.28, b.start > 0.01 { f = min(f, max(0, (t - b.start) / 0.28)) }
            if b.end - t < 0.28 { f = min(f, max(0, (b.end - t) / 0.28)) }
        }
        return f
    }

    private static func captionLayers(size: CGSize, captions: [MomentCaption], accent: ExportSnapshot) -> (CALayer, CALayer) {
        let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: size)
        let video = CALayer(); video.frame = CGRect(origin: .zero, size: size); parent.addSublayer(video)
        for cap in captions {
            let box = CALayer()
            let w = size.width * 0.86, h: CGFloat = 92
            box.frame = CGRect(x: (size.width - w) / 2, y: size.height * 0.10, width: w, height: h)
            box.cornerRadius = 18
            box.backgroundColor = captionBackground(cap.style, accent: accent)
            box.opacity = 0
            let text = CATextLayer()
            text.frame = CGRect(x: 18, y: 18, width: w - 36, height: h - 36)
            text.string = cap.text
            text.fontSize = cap.style == .stamp ? 40 : 44
            text.font = CTFontCreateWithName("Helvetica-Bold" as CFString, 44, nil)
            text.foregroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            text.alignmentMode = .center
            text.contentsScale = 2
            text.isWrapped = true
            box.addSublayer(text)
            let begin = AVCoreAnimationBeginTimeAtZero + cap.start
            let fadeIn = CABasicAnimation(keyPath: "opacity"); fadeIn.fromValue = 0; fadeIn.toValue = 1
            fadeIn.beginTime = begin; fadeIn.duration = 0.18; fadeIn.fillMode = .backwards
            let fadeOut = CABasicAnimation(keyPath: "opacity"); fadeOut.fromValue = 1; fadeOut.toValue = 0
            fadeOut.beginTime = begin + max(0.2, cap.duration - 0.18); fadeOut.duration = 0.18; fadeOut.fillMode = .forwards
            box.add(fadeIn, forKey: "in"); box.add(fadeOut, forKey: "out")
            if cap.style == .pop {
                let pop = CABasicAnimation(keyPath: "transform.scale"); pop.fromValue = 0.82; pop.toValue = 1
                pop.beginTime = begin; pop.duration = 0.22; pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
                box.add(pop, forKey: "pop")
            }
            // Keep visible between its fades: a hold animation pins opacity to 1.
            let hold = CABasicAnimation(keyPath: "opacity"); hold.fromValue = 1; hold.toValue = 1
            hold.beginTime = begin + 0.18; hold.duration = max(0.05, cap.duration - 0.36); hold.fillMode = .backwards
            box.add(hold, forKey: "hold")
            parent.addSublayer(box)
        }
        return (parent, video)
    }

    private static func captionBackground(_ style: CaptionStyle, accent: ExportSnapshot) -> CGColor {
        switch style {
        case .pop: return CGColor(red: accent.accentR, green: accent.accentG, blue: accent.accentB, alpha: 0.88)
        case .stamp: return CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 0.92)
        case .soft: return CGColor(red: 1, green: 1, blue: 1, alpha: 0.28)
        case .typewriter: return CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 0.75)
        }
    }

    static func export(_ project: ExportSnapshot) async throws -> URL {
        let (composition, videoComp, audioMix) = try await build(project)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("nu-moments-\(project.id.uuidString.prefix(8)).mp4")
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failed("Export session unavailable.")
        }
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = videoComp
        session.audioMix = audioMix
        session.metadata = [ AVMutableMetadataItem().then { $0.identifier = .commonIdentifierTitle; $0.value = project.title as NSString } ]
        await session.export()
        if session.status == .completed { return out }
        throw ExportError.failed(session.error?.localizedDescription ?? "Export failed.")
    }

    private static func fitTransform(for track: AVAssetTrack, canvas: CGSize) -> CGAffineTransform {
        let natural = track.naturalSize.applying(track.preferredTransform)
        let w = abs(natural.width), h = abs(natural.height)
        guard w > 1, h > 1 else { return .identity }
        let scale = max(canvas.width / w, canvas.height / h)
        var tr = track.preferredTransform
        tr = tr.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let sw = w * scale, sh = h * scale
        tr = tr.concatenating(CGAffineTransform(translationX: (canvas.width - sw) / 2, y: (canvas.height - sh) / 2))
        return tr
    }

    private static func stillSegment(url: URL, duration: TimeInterval, size: CGSize, look: MomentLook, accent: ExportSnapshot) async throws -> AVAsset {
        #if canImport(UIKit)
        guard let image = UIImage(contentsOfFile: url.path) else { throw ExportError.failed("Could not read photo.") }
        let renderer = UIGraphicsImageRenderer(size: size)
        let framed = renderer.image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let aspect = image.size.width / max(image.size.height, 1)
            var draw = CGRect(origin: .zero, size: size)
            if aspect > size.width / size.height { draw.size.width = size.height * aspect; draw.origin.x = (size.width - draw.size.width) / 2 }
            else { draw.size.height = size.width / aspect; draw.origin.y = (size.height - draw.size.height) / 2 }
            image.draw(in: draw)
        }
        let filtered = LookFilter.apply(look, to: CIImage(image: framed) ?? CIImage(color: .black), canvas: size)
        let ctx = CIContext()
        let ui = ctx.createCGImage(filtered, from: CGRect(origin: .zero, size: size)).map { UIImage(cgImage: $0) } ?? framed
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).mp4")
        try await writeStillVideo(image: ui, duration: duration, to: tmp, size: size)
        return AVURLAsset(url: tmp)
        #else
        throw ExportError.failed("Photo stills need UIKit on this build.")
        #endif
    }

    #if canImport(UIKit)
    private static func writeStillVideo(image: UIImage, duration: TimeInterval, to url: URL, size: CGSize) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        guard let buffer = pixelBuffer(from: image, size: size) else { throw ExportError.failed("Pixel buffer failed.") }
        let frameDuration = CMTime(value: 1, timescale: 30)
        var frame: Int64 = 0; let total = Int64(duration * 30)
        while frame < total {
            if input.isReadyForMoreMediaData { adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(frame))); frame += 1 }
            else { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        input.markAsFinished(); await writer.finishWriting()
        if writer.status != .completed { throw ExportError.failed(writer.error?.localizedDescription ?? "Still encode failed.") }
    }

    private static func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB, attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue), let cg = image.cgImage else { return nil }
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        return buffer
    }
    #endif
}

/// Shared CoreImage look chain (used for video frames, stills and carousel slides).
enum LookFilter {
    static func apply(_ look: MomentLook, to image: CIImage, canvas: CGSize) -> CIImage {
        var out = image
        func run(_ name: String, _ params: [String: Any]) {
            guard let f = CIFilter(name: name) else { return }
            f.setValue(out, forKey: kCIInputImageKey)
            for (k, v) in params { f.setValue(v, forKey: k) }
            if let o = f.outputImage { out = o }
        }
        switch look {
        case .natural: break
        case .film: run("CISepiaTone", ["inputIntensity": 0.35]); run("CIColorControls", [kCIInputSaturationKey: 1.15, kCIInputContrastKey: 1.06]); run("CIVignette", ["inputIntensity": 0.7, "inputRadius": 1.2])
        case .printed: run("CIColorControls", [kCIInputSaturationKey: 0.75, kCIInputContrastKey: 1.22, kCIInputBrightnessKey: 0.02])
        case .haze: run("CIColorControls", [kCIInputSaturationKey: 0.82, kCIInputBrightnessKey: 0.07, kCIInputContrastKey: 0.94]); run("CIGaussianBlur", [kCIInputRadiusKey: 1.1])
        case .digitalPop: run("CIColorControls", [kCIInputSaturationKey: 1.5, kCIInputContrastKey: 1.1])
        case .vhs: run("CIHueAdjust", ["inputAngle": 0.3]); run("CIColorControls", [kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.05])
        case .mono: run("CIPhotoEffectMono", [:])
        }
        return out.cropped(to: CGRect(origin: .zero, size: canvas))
    }
}

private extension AVMutableMetadataItem {
    func then(_ block: (AVMutableMetadataItem) -> Void) -> AVMutableMetadataItem { block(self); return self }
}
