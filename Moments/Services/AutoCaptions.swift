// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreImage
import Foundation
import Photos
import Speech
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
            case .noAudio: "That clip has no audio to caption. Add a clip with sound, or type captions."
            case .noSpeech: "No speech was heard in that clip on this device."
            }
        }
    }

    static func captions(for project: ExportSnapshot) async throws -> [MomentCaption] {
        guard let clip = project.clips.first(where: { !$0.isPhoto }) else { throw CaptionsError.noAudio }
        let audioURL = try await extractAudio(from: clip)
        return try await transcribe(audioURL: audioURL, style: .pop)
    }

    private static func extractAudio(from clip: MomentClip) async throws -> URL {
        let asset = AVURLAsset(url: clip.url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw CaptionsError.noAudio }
        let out = MediaImport.mediaDir.appendingPathComponent("caption-audio-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw CaptionsError.noAudio }
        session.outputURL = out
        session.outputFileType = .m4a
        let range = CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: 600),
                                duration: CMTime(seconds: min(clip.outDuration * max(clip.speed, 0.25), clip.duration), preferredTimescale: 600))
        session.timeRange = range
        await session.export()
        guard session.status == .completed else { throw CaptionsError.noAudio }
        return out
    }

    private static func transcribe(audioURL: URL, style: CaptionStyle) async throws -> [MomentCaption] {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw CaptionsError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw CaptionsError.noSpeech }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        struct Seg: Sendable { var text: String; var timestamp: TimeInterval; var duration: TimeInterval }
        let segments: [Seg] = try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { r, e in
                if let e { cont.resume(throwing: e); return }
                if let r, r.isFinal {
                    cont.resume(returning: r.bestTranscription.segments.map { Seg(text: $0.substring, timestamp: $0.timestamp, duration: $0.duration) })
                }
            }
        }
        guard !segments.isEmpty else { throw CaptionsError.noSpeech }
        // Group words into short caption lines (~2.2s each).
        var captions: [MomentCaption] = []
        var words: [String] = []
        var start: TimeInterval = segments.first?.timestamp ?? 0
        var lastEnd: TimeInterval = start
        func flush() {
            guard !words.isEmpty else { return }
            captions.append(MomentCaption(text: words.joined(separator: " "), style: style, start: start, duration: max(0.8, lastEnd - start)))
            words = []
        }
        for seg in segments {
            if seg.timestamp - start > 2.2, !words.isEmpty { flush(); start = seg.timestamp }
            words.append(seg.text)
            lastEnd = seg.timestamp + seg.duration
        }
        flush()
        return captions
    }
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

/// Save finished reels / carousel slides to the user's photo library (add-only).
enum PhotosSave {
    static func saveVideo(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "nu.moments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photo library add access is off. Export and use Share instead."])
        }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
    }
    static func saveImages(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "nu.moments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photo library add access is off. Export and use Share instead."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            for u in urls { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: u) }
        }
    }
}

/// Carousel slides: one still per clip (photo, or a video frame), look + slide number burned in.
enum CarouselExport {
    static func slides(for project: ExportSnapshot) async throws -> [URL] {
        let size = CGSize(width: 1080, height: 1350)
        var urls: [URL] = []
        for (i, clip) in project.clips.enumerated() {
            let base: CIImage
            if clip.isPhoto {
                guard let img = CIImage(contentsOf: clip.url) else { continue }
                base = img
            } else {
                let asset = AVURLAsset(url: clip.url)
                let gen = AVAssetImageGenerator(asset: asset); gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 1080, height: 1350)
                let cg = try gen.copyCGImage(at: CMTime(seconds: clip.inPoint + 0.4, preferredTimescale: 600), actualTime: nil)
                base = CIImage(cgImage: cg)
            }
            let scale = max(size.width / base.extent.width, size.height / base.extent.height)
            var img = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let dx = (size.width - img.extent.width) / 2 - img.extent.minX
            let dy = (size.height - img.extent.height) / 2 - img.extent.minY
            img = img.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: CGRect(origin: .zero, size: size))
            img = LookFilter.apply(project.look, to: img, canvas: size)
            guard let cg = CIContext().createCGImage(img, from: CGRect(origin: .zero, size: size)) else { continue }
            #if canImport(UIKit)
            let renderer = UIGraphicsImageRenderer(size: size)
            let data = renderer.jpegData(withCompressionQuality: 0.9) { _ in
                UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
                let label = "\(i + 1) / \(project.clips.count)  ·  \(project.title)"
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 34), .foregroundColor: UIColor.white]
                label.draw(at: CGPoint(x: 44, y: size.height - 84), withAttributes: attrs)
                if let cap = project.captions.first(where: { $0.start <= Double(i) * 2.4 && Double(i) * 2.4 < $0.start + $0.duration }) {
                    (cap.text as NSString).draw(at: CGPoint(x: 44, y: size.height - 150), withAttributes: attrs)
                }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("slide-\(i + 1)-\(project.id.uuidString.prefix(6)).jpg")
            try data.write(to: url); urls.append(url)
            #endif
        }
        guard !urls.isEmpty else { throw CompositionExport.ExportError.failed("No slides could be made.") }
        return urls
    }
}
