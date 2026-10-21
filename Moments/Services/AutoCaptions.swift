// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Photos
import Speech
import UniformTypeIdentifiers
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// On-device speech captions. Audio is extracted on the phone, recognised
/// with `requiresOnDeviceRecognition`, and never sent to a server.
enum AutoCaptions {
    enum CaptionsError: Error, LocalizedError {
        case notAuthorized, noAudio, noSpeech
        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Speech recognition is off for nu.moments. Turn it on in Settings, or type captions instead."
            case .noAudio: "There is no sound to caption. Add a clip with speech or record a voice-over, or type captions."
            case .noSpeech: "No speech was heard on this device."
            }
        }
    }

    /// Captions every clip with sound (and the voice-over), with word timings placed on the timeline.
    static func captions(for project: ExportSnapshot) async throws -> [MomentCaption] {
        try await authorize()
        let starts = Timeline.starts(clips: project.clips, layout: project.layout)
        var words: [CaptionWord] = []
        var heardAudio = false
        for clip in project.clips where !clip.isPhoto && !clip.muted && !clip.reversed {
            guard let audio = try? await extractAudio(from: clip) else { continue }
            heardAudio = true
            let t0 = starts[clip.id] ?? 0
            let speed = max(clip.speed, 0.25)
            for w in (try? await transcribe(audio)) ?? [] {
                let s = t0 + w.start / speed
                guard s < t0 + clip.outDuration else { continue }
                words.append(CaptionWord(text: w.text, start: s, duration: w.duration / speed))
            }
        }
        if let vo = project.voiceoverURL {
            heardAudio = true
            words += (try? await transcribe(vo)) ?? []
        }
        guard heardAudio else { throw CaptionsError.noAudio }
        guard !words.isEmpty else { throw CaptionsError.noSpeech }
        return group(words.sorted { $0.start < $1.start }, style: .pop)
    }

    /// Short caption lines (about 2.2 s or 5 words), each keeping its word timings.
    static func group(_ words: [CaptionWord], style: CaptionStyle) -> [MomentCaption] {
        var out: [MomentCaption] = []
        var line: [CaptionWord] = []
        func flush() {
            guard let first = line.first, let last = line.last else { return }
            let end = last.start + last.duration
            out.append(MomentCaption(text: line.map(\.text).joined(separator: " "), style: style,
                                     start: first.start, duration: max(0.8, end - first.start), words: line))
            line = []
        }
        for w in words {
            if let first = line.first, w.start - first.start > 2.2 || line.count >= 5 { flush() }
            line.append(w)
        }
        flush()
        return out
    }

    private static func authorize() async throws {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw CaptionsError.notAuthorized }
    }

    private static func extractAudio(from clip: MomentClip) async throws -> URL {
        let asset = AVURLAsset(url: clip.url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw CaptionsError.noAudio }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("caption-audio-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw CaptionsError.noAudio }
        session.timeRange = CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: 600),
                                        duration: CMTime(seconds: min(clip.outDuration * max(clip.speed, 0.25), clip.duration - clip.inPoint), preferredTimescale: 600))
        do { try await session.export(to: out, as: .m4a) } catch { throw CaptionsError.noAudio }
        return out
    }

    /// Word timings in the file's own time.
    private static func transcribe(_ audioURL: URL) async throws -> [CaptionWord] {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw CaptionsError.noSpeech }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            recognizer.recognitionTask(with: request) { r, e in
                if let e { if once.take() { cont.resume(throwing: e) }; return }
                if let r, r.isFinal, once.take() {
                    cont.resume(returning: r.bestTranscription.segments.map { CaptionWord(text: $0.substring, start: $0.timestamp, duration: $0.duration) })
                }
            }
        }
    }
}

/// Guards a continuation against a second resume.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// Generates a simple kick/hat beat track (WAV) at a BPM, on device — no catalogue needed.
enum BeatTrack {
    static func generate(bpm: Double, seconds: TimeInterval = 30) -> URL {
        let sr = 44_100.0
        let frames = Int(seconds * sr)
        var samples = [Float](repeating: 0, count: frames)
        let beat = 60.0 / bpm
        var t = 0.0
        while t < seconds {
            addKick(into: &samples, at: t, sr: sr, strong: true)
            addKick(into: &samples, at: t + beat / 2, sr: sr, strong: false)
            t += beat
        }
        let url = MediaImport.mediaDir.appendingPathComponent("beat-\(Int(bpm))bpm.wav")
        writeWAV(samples: samples, sampleRate: Int(sr), to: url)
        return url
    }

    private static func addKick(into samples: inout [Float], at time: Double, sr: Double, strong: Bool) {
        let start = Int(time * sr)
        let len = Int(0.18 * sr)
        for i in 0..<len where start + i < samples.count {
            let p = Double(i) / sr
            let freq = strong ? 120.0 - 70.0 * (p / 0.18) : 8000.0
            let env = exp(-p * (strong ? 28 : 90))
            samples[start + i] += Float(sin(2 * Double.pi * freq * p) * env * (strong ? 0.85 : 0.12))
        }
    }

    private static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) {
        var data = Data()
        let byteRate = sampleRate * 2
        data.append("RIFF".data(using: .ascii)!); append32(&data, UInt32(36 + samples.count * 2)); data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); append32(&data, 16); append16(&data, 1); append16(&data, 1)
        append32(&data, UInt32(sampleRate)); append32(&data, UInt32(byteRate)); append16(&data, 2); append16(&data, 16)
        data.append("data".data(using: .ascii)!); append32(&data, UInt32(samples.count * 2))
        for s in samples { append16(&data, UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        try? data.write(to: url)
    }
    private static func append16(_ d: inout Data, _ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private static func append32(_ d: inout Data, _ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
}

/// Vision person segmentation for photos: subject over a soft blurred backdrop.
enum SubjectLift {
    enum LiftError: Error, LocalizedError {
        case noPerson, failed
        var errorDescription: String? { self == .noPerson ? "No person was found in that photo on this device." : "Subject lift failed on this device." }
    }

    static func lift(photoURL: URL, accent: ExportSnapshot) async throws -> URL {
        #if canImport(UIKit)
        guard let ui = UIImage(contentsOfFile: photoURL.path), let cg = ui.cgImage else { throw LiftError.failed }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([request])
        guard let obs = request.results?.first else { throw LiftError.noPerson }
        let original = CIImage(cgImage: cg)
        let mask = CIImage(cvPixelBuffer: obs.pixelBuffer).transformed(by: CGAffineTransform(
            scaleX: original.extent.width / CIImage(cvPixelBuffer: obs.pixelBuffer).extent.width,
            y: original.extent.height / CIImage(cvPixelBuffer: obs.pixelBuffer).extent.height))
        var backdrop = original
        if let blur = CIFilter(name: "CIGaussianBlur") { blur.setValue(original.clampedToExtent(), forKey: kCIInputImageKey); blur.setValue(18, forKey: kCIInputRadiusKey); backdrop = (blur.outputImage ?? original).cropped(to: original.extent) }
        if let dark = CIFilter(name: "CIColorControls") { dark.setValue(backdrop, forKey: kCIInputImageKey); dark.setValue(0.75, forKey: kCIInputSaturationKey); dark.setValue(-0.06, forKey: kCIInputBrightnessKey); backdrop = dark.outputImage ?? backdrop }
        guard let blend = CIFilter(name: "CIBlendWithMask") else { throw LiftError.failed }
        blend.setValue(original, forKey: kCIInputImageKey)
        blend.setValue(backdrop, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let out = blend.outputImage, let rendered = CIContext().createCGImage(out, from: original.extent) else { throw LiftError.failed }
        let dest = MediaImport.mediaDir.appendingPathComponent("lift-\(UUID().uuidString).jpg")
        guard let jpg = UIImage(cgImage: rendered).jpegData(compressionQuality: 0.92) else { throw LiftError.failed }
        try jpg.write(to: dest)
        return dest
        #else
        throw LiftError.failed
        #endif
    }
}

/// Save finished reels and carousel slides to the photo library (add-only).
enum PhotosSave {
    private static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "nu.moments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photo library add access is off. Export and use Share instead."])
        }
    }
    static func saveVideo(_ url: URL) async throws { try await save([url]) }
    static func saveImages(_ urls: [URL]) async throws { try await save(urls) }
    /// Photos and videos in order (a mixed carousel).
    static func save(_ urls: [URL]) async throws {
        try await authorize()
        try await PHPhotoLibrary.shared().performChanges {
            for u in urls {
                if ["mp4", "mov", "m4v"].contains(u.pathExtension.lowercased()) {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: u)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: u)
                }
            }
        }
    }
}

/// Carousel slides (4:5) through the same renderer as the reel: photo slides become stills,
/// video slides stay video. Seamless mode spreads one continuous picture across the slides.
enum CarouselExport {
    static let slideSize = CGSize(width: 1080, height: 1350)

    static func slides(for project: ExportSnapshot, seamless: Bool = false, panels: Int = 3) async throws -> [URL] {
        if seamless { return try await panorama(project, panels: max(2, min(10, panels))) }
        var urls: [URL] = []
        for (i, clip) in project.clips.prefix(20).enumerated() {
            let one = project.with(clips: [clip], layout: .single, format: .story, keepAudio: !clip.isPhoto)
            if clip.isPhoto {
                let cg = try await CompositionExport.frame(one, at: min(1.2, clip.outDuration * 0.6), maxSize: slideSize, preview: false)
                urls.append(try writeJPEG(cg, name: "slide-\(i + 1)-\(project.id.uuidString.prefix(6))"))
            } else {
                let mov = try await CompositionExport.export(one)
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("slide-\(i + 1)-\(project.id.uuidString.prefix(6)).mp4")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: mov, to: dest)
                urls.append(dest)
            }
        }
        guard !urls.isEmpty else { throw CompositionExport.ExportError.failed("No slides could be made.") }
        return urls
    }

    /// One wide picture cut into `panels` slides that line up edge to edge when swiped.
    /// A single photo spans every slide; several clips sit side by side with no gutters.
    private static func panorama(_ project: ExportSnapshot, panels: Int) async throws -> [URL] {
        let W = slideSize.width * CGFloat(panels), H = slideSize.height
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        var strip = CIImage(color: CIColor(cgColor: Hex.cg(project.backdropHex))).cropped(to: canvas)
        let clips = Array(project.clips.prefix(panels))
        guard !clips.isEmpty else { throw CompositionExport.ExportError.empty }
        let cellW = W / CGFloat(clips.count)
        for (i, clip) in clips.enumerated() {
            guard let img = try await still(of: clip) else { continue }
            let cell = CGRect(x: CGFloat(i) * cellW, y: 0, width: cellW, height: H)
            let s = max(cell.width / img.extent.width, cell.height / img.extent.height)
            var placed = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            placed = placed.transformed(by: CGAffineTransform(translationX: cell.midX - placed.extent.midX, y: cell.midY - placed.extent.midY))
            placed = Adjust.apply(clip.adjust, to: placed, k: 1).cropped(to: cell)
            strip = placed.composited(over: strip)
        }
        strip = LookFilter.apply(project.look, to: strip, canvas: canvas.size)
        let plan = RenderPlan(canvas: canvas.size, look: project.look, transition: project.transition,
                              backdrop: CIColor(cgColor: Hex.cg(project.backdropHex)), accent: CIColor(red: project.accentR, green: project.accentG, blue: project.accentB),
                              effects: [], statics: [], videoOverlays: [:], captions: [], captionLook: project.captionLook)
        for o in project.overlays where o.kind != .media || !o.mediaIsVideo {
            let img: CIImage?
            if let url = o.mediaURL { img = CIImage(contentsOf: url) } else { img = TextRaster.overlay(o, canvasWidth: slideSize.width) }
            guard let img else { continue }
            strip = Overlays.place(img, overlay: o, t: o.start + o.duration / 2, plan: plan).composited(over: strip)
        }
        let ctx = CIContext()
        var urls: [URL] = []
        for p in 0..<panels {
            let r = CGRect(x: CGFloat(p) * slideSize.width, y: 0, width: slideSize.width, height: H)
            guard let cg = ctx.createCGImage(strip, from: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { continue }
            urls.append(try writeJPEG(cg, name: "seamless-\(p + 1)-\(project.id.uuidString.prefix(6))"))
        }
        return urls
    }

    private static func still(of clip: MomentClip) async throws -> CIImage? {
        if clip.isPhoto {
            guard let src = CGImageSourceCreateWithURL(clip.url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { return nil }
            return CIImage(cgImage: cg)
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: clip.sourceURL))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 2160, height: 2700)
        let (cg, _) = try await gen.image(at: CMTime(seconds: clip.inPoint + min(0.4, clip.outDuration / 2), preferredTimescale: 600))
        return CIImage(cgImage: cg)
    }

    private static func writeJPEG(_ cg: CGImage, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).jpg")
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CompositionExport.ExportError.failed("Slide could not be written.")
        }
        CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw CompositionExport.ExportError.failed("Slide could not be written.") }
        return url
    }
}
