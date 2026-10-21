// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreImage
import Foundation

/// Builds the AVFoundation composition for a project. Preview, frame grabs and export all go
/// through `MomentCompositor`, so the file matches what you saw.
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

    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVAudioMix?
        let plan: RenderPlan
    }

    @MainActor
    static func export(_ project: MomentProject, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await export(ExportSnapshot(project: project), progress: progress)
    }

    static func makeComposition(_ project: ExportSnapshot, preview: Bool = false) async throws -> (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?) {
        let b = try await build(project, preview: preview)
        return (b.composition, b.videoComposition, b.audioMix)
    }

    static func renderSize(_ s: ExportSnapshot, preview: Bool) -> CGSize {
        let scale = preview ? min(1, s.export.resolution.scale) * (2.0 / 3.0) : s.export.resolution.scale
        let base = s.format.size
        func even(_ v: Double) -> CGFloat { CGFloat(Int((v / 2).rounded()) * 2) }
        return CGSize(width: even(base.width * scale), height: even(base.height * scale))
    }

    static func build(_ project: ExportSnapshot, preview: Bool = false) async throws -> Built {
        guard !project.clips.isEmpty else { throw ExportError.empty }
        let size = renderSize(project, preview: preview)
        let composition = AVMutableComposition()
        let cellCount = max(1, project.layout.count)

        // Two track sets, alternating per group, so a fade can overlap the next group.
        let crossfade = project.transition == .fade
        var cellTracks: [AVMutableCompositionTrack] = []
        for _ in 0..<(cellCount * (crossfade ? 2 : 1)) {
            guard let t = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ExportError.failed("Could not create a video track.")
            }
            cellTracks.append(t)
        }
        let clipAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let voiceTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var specs: [LayerSpec] = []
        var volumeRamps: [(CMTime, Float)] = []
        var cursor = 0.0
        let groups = Timeline.groups(project.clips, layout: project.layout)
        let cells = project.layout.cells

        for (gi, group) in groups.enumerated() {
            let groupDur = group.map(\.outDuration).max() ?? 0
            guard groupDur > 0 else { continue }
            let at = CMTime(seconds: cursor, preferredTimescale: 600)
            let next = gi + 1 < groups.count ? (groups[gi + 1].map(\.outDuration).max() ?? 0) : 0
            let tail = crossfade ? min(0.3, next / 3) : 0
            for (ci, clip) in group.enumerated() {
                let track = cellTracks[ci + (crossfade && gi % 2 == 1 ? cellCount : 0)]
                let placed = try await insert(clip: clip, into: track, audio: ci == 0 ? clipAudio : nil, at: at, limit: groupDur, extra: tail)
                guard let placed else { continue }
                if ci == 0, clipAudio != nil {
                    volumeRamps.append((at, clip.muted || clip.reversed ? 0 : Float(clip.volume)))
                }
                specs.append(LayerSpec(trackID: track.trackID, cell: cells[ci], clip: clip, start: cursor, duration: placed.duration,
                                       orientation: placed.orientation, isFirst: gi == 0, isLast: gi == groups.count - 1, tail: placed.tail))
            }
            cursor += groupDur
        }
        guard cursor > 0 else { throw ExportError.failed("No usable clips.") }
        let total = CMTime(seconds: cursor, preferredTimescale: 600)

        // Photo and video overlays (picture in picture, green screen, cutout).
        var videoOverlays: [CMPersistentTrackID: MomentOverlay] = [:]
        var statics: [StaticLayer] = []
        for o in project.overlays {
            switch o.kind {
            case .media:
                guard let url = o.mediaURL else { continue }
                if o.mediaIsVideo {
                    let asset = AVURLAsset(url: url)
                    guard let src = try await asset.loadTracks(withMediaType: .video).first,
                          let t = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    let dur = try await asset.load(.duration)
                    let use = CMTimeMinimum(dur, CMTime(seconds: min(o.duration, max(0, cursor - o.start)), preferredTimescale: 600))
                    guard use.seconds > 0.05 else { continue }
                    try t.insertTimeRange(CMTimeRange(start: .zero, duration: use), of: src, at: CMTime(seconds: o.start, preferredTimescale: 600))
                    t.preferredTransform = try await src.load(.preferredTransform)
                    var adjusted = o
                    adjusted.duration = use.seconds
                    videoOverlays[t.trackID] = adjusted
                } else if let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
                    statics.append(StaticLayer(overlay: o, image: img))
                }
            case .sticker, .drawing:
                if let url = o.mediaURL, let img = CIImage(contentsOf: url) {
                    statics.append(StaticLayer(overlay: o, image: img))
                } else if let img = TextRaster.overlay(o, canvasWidth: size.width) {
                    statics.append(StaticLayer(overlay: o, image: img))
                }
            case .text:
                if let img = TextRaster.overlay(o, canvasWidth: size.width) { statics.append(StaticLayer(overlay: o, image: img)) }
            }
        }

        // Captions, pre-rendered once (with a per-word highlight when timings exist).
        let accent = CGColor(srgbRed: project.accentR, green: project.accentG, blue: project.accentB, alpha: 1)
        var captions: [CaptionRender] = []
        for c in project.captions {
            guard let base = TextRaster.caption(c, look: project.captionLook, accent: accent, canvasWidth: size.width) else { continue }
            var per: [CIImage] = []
            if project.captionLook.wordHighlight, c.words.count > 1 {
                per = (0..<c.words.count).compactMap { TextRaster.caption(c, look: project.captionLook, accent: accent, canvasWidth: size.width, highlight: $0) }
            }
            captions.append(CaptionRender(caption: c, base: base, perWord: per))
        }

        let bd = Hex.rgba(project.backdropHex)
        let plan = RenderPlan(canvas: size, look: project.look, transition: project.transition,
                              backdrop: CIColor(red: bd.0, green: bd.1, blue: bd.2),
                              accent: CIColor(red: project.accentR, green: project.accentG, blue: project.accentB),
                              effects: project.effects, statics: statics, videoOverlays: videoOverlays,
                              captions: captions, captionLook: project.captionLook)

        // Instructions: split the timeline wherever a clip or a video overlay starts or ends.
        var cuts = Set<Double>([0, cursor])
        for s in specs { cuts.insert(s.start); cuts.insert(min(cursor, s.start + s.duration)); cuts.insert(min(cursor, s.start + s.duration + s.tail)) }
        for o in videoOverlays.values { cuts.insert(max(0, o.start)); cuts.insert(min(cursor, o.start + o.duration)) }
        let points = cuts.filter { $0 >= 0 && $0 <= cursor }.sorted()
        var instructions: [MomentInstruction] = []
        var prev = CMTime.zero
        for (a, b) in zip(points, points.dropFirst()) where b - a > 0.0005 {
            let mid = (a + b) / 2
            let active = specs.filter { mid >= $0.start && mid < $0.start + $0.duration + $0.tail }
            let overlayIDs = videoOverlays.filter { mid >= $0.value.start && mid < $0.value.start + $0.value.duration }.map(\.key)
            let end = b >= cursor - 0.0005 ? total : CMTime(seconds: b, preferredTimescale: 600)
            instructions.append(MomentInstruction(timeRange: CMTimeRange(start: prev, end: end), layers: active, overlayTracks: overlayIDs, plan: plan))
            prev = end
        }

        let videoComp = AVMutableVideoComposition()
        videoComp.customVideoCompositorClass = MomentCompositor.self
        videoComp.renderSize = size
        videoComp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(preview ? 30 : max(24, project.export.fps)))
        videoComp.instructions = instructions

        // Audio: music, voice-over, and clip sound with per-clip volume.
        if let music = project.musicURL, let mTrack = musicTrack {
            let song = AVURLAsset(url: music)
            if let src = try await song.loadTracks(withMediaType: .audio).first {
                let songDur = try await song.load(.duration)
                try? mTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(total, songDur)), of: src, at: .zero)
            }
        }
        if let vo = project.voiceoverURL, let vTrack = voiceTrack {
            let asset = AVURLAsset(url: vo)
            if let src = try await asset.loadTracks(withMediaType: .audio).first {
                let d = try await asset.load(.duration)
                try? vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(total, d)), of: src, at: .zero)
            }
        }
        var params: [AVMutableAudioMixInputParameters] = []
        let hasVoice = !(voiceTrack?.segments.isEmpty ?? true)
        if let m = musicTrack, !m.segments.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: m)
            p.setVolume(Float(project.musicVolume * (hasVoice ? 0.45 : 1)), at: .zero)
            params.append(p)
        }
        if let v = voiceTrack, hasVoice {
            let p = AVMutableAudioMixInputParameters(track: v)
            p.setVolume(Float(project.voiceoverVolume), at: .zero)
            params.append(p)
        }
        if let a = clipAudio, !a.segments.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: a)
            let duck: Float = project.musicURL == nil ? 1 : 0.6
            for (time, vol) in volumeRamps { p.setVolume(vol * duck, at: time) }
            params.append(p)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params

        return Built(composition: composition, videoComposition: videoComp, audioMix: params.isEmpty ? nil : mix, plan: plan)
    }

    private struct Placed { let duration: Double; let orientation: CGImagePropertyOrientation; var tail: Double = 0 }

    /// `extra` seconds of picture (no sound) run on past the clip, when the source has them, for a cross-fade.
    private static func insert(clip: MomentClip, into track: AVMutableCompositionTrack, audio: AVMutableCompositionTrack?,
                               at: CMTime, limit: Double, extra: Double = 0) async throws -> Placed? {
        if clip.isPhoto {
            let still = try await StillVideo.url(for: clip.url, duration: max(clip.outDuration, limit) + extra)
            let asset = AVURLAsset(url: still)
            guard let src = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let avail = try await asset.load(.duration).seconds
            let d = min(clip.outDuration, avail)
            let full = min(clip.outDuration + extra, avail)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: full, preferredTimescale: 600)), of: src, at: at)
            return Placed(duration: d, orientation: .up, tail: full - d)
        }
        let asset = AVURLAsset(url: clip.sourceURL)
        guard let src = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let speed = max(0.1, clip.speed)
        let avail = max(0.1, clip.duration - clip.inPoint)
        let sourceDur = min(clip.outDuration * speed, avail)
        let outDur = sourceDur / speed
        let videoDur = clip.reversed ? sourceDur : min((clip.outDuration + extra) * speed, avail)
        let inPoint = clip.reversed ? max(0, clip.duration - clip.inPoint - sourceDur) : clip.inPoint
        let range = CMTimeRange(start: CMTime(seconds: inPoint, preferredTimescale: 600), duration: CMTime(seconds: sourceDur, preferredTimescale: 600))
        let videoRange = CMTimeRange(start: range.start, duration: CMTime(seconds: videoDur, preferredTimescale: 600))
        try track.insertTimeRange(videoRange, of: src, at: at)
        let scaled = CMTime(seconds: outDur, preferredTimescale: 600)
        let videoScaled = CMTime(seconds: videoDur / speed, preferredTimescale: 600)
        if speed != 1 { track.scaleTimeRange(CMTimeRange(start: at, duration: videoRange.duration), toDuration: videoScaled) }

        if let audio, !clip.muted, !clip.reversed {
            if let override = clip.audioURL {
                let a = AVURLAsset(url: override)
                if let srcA = try await a.loadTracks(withMediaType: .audio).first {
                    let ad = try await a.load(.duration)
                    let r = CMTimeRange(start: range.start, duration: CMTimeMinimum(range.duration, CMTimeSubtract(ad, range.start)))
                    if r.duration.seconds > 0 { try? audio.insertTimeRange(r, of: srcA, at: at) }
                }
            } else if let srcA = try await asset.loadTracks(withMediaType: .audio).first {
                try? audio.insertTimeRange(range, of: srcA, at: at)
            }
            if speed != 1 { audio.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: scaled) }
        }
        let tr = try await src.load(.preferredTransform)
        return Placed(duration: outDur, orientation: orientation(tr), tail: max(0, videoDur / speed - outDur))
    }

    static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        if abs(t.b - 1) < 0.01, abs(t.c + 1) < 0.01 { return .right }
        if abs(t.b + 1) < 0.01, abs(t.c - 1) < 0.01 { return .left }
        if abs(t.a + 1) < 0.01, abs(t.d + 1) < 0.01 { return .down }
        return .up
    }

    // MARK: Export

    static func export(_ project: ExportSnapshot, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let built = try await build(project)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("nu-moments-\(project.id.uuidString.prefix(8))-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: out)
        let preset = project.export.hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw ExportError.failed("Export session unavailable.")
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = project.title as NSString
        session.metadata = [title]
        let box = SessionBox(session: session)
        let watcher = progress.map { cb in
            Task {
                for await state in box.session.states(updateInterval: 0.25) {
                    if case .exporting(let p) = state { cb(p.fractionCompleted) }
                }
            }
        }
        defer { watcher?.cancel() }
        do {
            try await session.export(to: out, as: .mp4)
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
        return out
    }

    /// One rendered frame at `time`, through the same compositor (for the editor canvas and slides).
    static func frame(_ project: ExportSnapshot, at time: Double, maxSize: CGSize = CGSize(width: 720, height: 1280), preview: Bool = true) async throws -> CGImage {
        let built = try await build(project, preview: preview)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.maximumSize = maxSize
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        let t = min(max(0, time), max(0, built.composition.duration.seconds - 0.02))
        let (image, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
        return image
    }
}

private struct SessionBox: @unchecked Sendable { let session: AVAssetExportSession }

/// Photos become short still-video files (one frame held), cached per photo.
enum StillVideo {
    static func url(for photo: URL, duration: Double) async throws -> URL {
        let d = max(0.5, (duration * 2).rounded(.up) / 2 + 0.5)
        let name = "still-\(photo.deletingPathExtension().lastPathComponent)-\(Int(d * 10)).mov"
        let dest = MediaImport.mediaDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let src = CGImageSourceCreateWithURL(photo as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 2160] as CFDictionary) else {
            throw CompositionExport.ExportError.failed("Could not read photo.")
        }
        let w = cg.width / 2 * 2, h = cg.height / 2 * 2
        let writer = try AVAssetWriter(outputURL: dest, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { throw CompositionExport.ExportError.failed(writer.error?.localizedDescription ?? "Still encode failed.") }
        writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buffer = pb else { throw CompositionExport.ExportError.failed("Pixel buffer failed.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for t in [0.0, d / 2] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: d, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw CompositionExport.ExportError.failed(writer.error?.localizedDescription ?? "Still encode failed.") }
        return dest
    }
}
