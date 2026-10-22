// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Vision

/// Datamosh baked into a new clip file on this device. Motion comes from Vision optical flow, snapped to 16-pixel
/// macroblocks the way a codec's motion vectors are, and drags old pixels around with no fresh picture until the
/// mosh ends and the real frame comes back, like a keyframe arriving.
enum Datamosh {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case fromPrevious, bloom, melt
        var id: String { rawValue }
        var label: String { switch self { case .fromPrevious: "From the clip before"; case .bloom: "Bloom"; case .melt: "Melt" } }
        var note: String {
            switch self {
            case .fromPrevious: "The last frame of the clip before is dragged by this clip's motion, then this clip snaps in."
            case .bloom: "One moment of motion repeats from the playhead, so pixels keep pushing outward."
            case .melt: "The clip moves only by its own motion vectors; Leak lets some real picture back in."
            }
        }
    }

    static let block = 16

    /// - Parameters:
    ///   - url: the clip's own file, full length; the result has the same length and timing.
    ///   - stuck: the picture `.fromPrevious` starts from (upright).
    ///   - start: seconds into the file where the mosh begins. `length` seconds later the real picture returns.
    ///   - amount: multiplies the motion vectors, so gentle footage still smears.
    ///   - leak: 0…1, how much real picture bleeds back in each frame.
    static func render(_ url: URL, stuck: CGImage?, mode: Mode, start: Double, length: Double, amount: Double = 3, leak: Double,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try await run(url, stuck: stuck, mode: mode, start: start, length: length, amount: amount, leak: leak, progress: progress)
        }.value
    }

    /// The last frame a clip shows on the timeline, upright.
    static func lastFrame(of clip: MomentClip) async throws -> CGImage {
        if clip.isPhoto {
            guard let src = CGImageSourceCreateWithURL(clip.url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 1920] as CFDictionary)
            else { throw CompositionExport.ExportError.failed("The clip before could not be read.") }
            return cg
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: clip.sourceURL))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = .zero
        let t = clip.inPoint + clip.outDuration * max(0.1, clip.speed) - 0.04
        return try await gen.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image
    }

    private struct Ptr<T>: @unchecked Sendable { let p: UnsafeMutablePointer<T> }
    private struct Vec { var x: Float; var y: Float }

    private static func run(_ url: URL, stuck: CGImage?, mode: Mode, start: Double, length: Double, amount: Double, leak: Double,
                            progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompositionExport.ExportError.failed("That clip has no video to mosh.")
        }
        let duration = max(0.01, try await asset.load(.duration).seconds)
        let natural = try await track.load(.naturalSize)
        let orient = CompositionExport.orientation(try await track.load(.preferredTransform))
        let sideways = orient == .left || orient == .right || orient == .leftMirrored || orient == .rightMirrored
        let up = sideways ? CGSize(width: natural.height, height: natural.width) : natural
        let fit = min(1, 1920 / max(up.width, up.height))
        let W = Int(up.width * fit) & ~1, H = Int(up.height * fit) & ~1
        guard W >= 64, H >= 64 else { throw CompositionExport.ExportError.failed("That clip is too small to mosh.") }
        let fw = max(32, W / 4), fh = max(32, H / 4)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)

        let out = MediaImport.mediaDir.appendingPathComponent("moshed-\(mode.rawValue)-\(UUID().uuidString.prefix(6)).mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: W, AVVideoHeightKey: H])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
        ])
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw CompositionExport.ExportError.failed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Datamosh failed.")
        }
        writer.startSession(atSourceTime: .zero)

        let ctx = CIContext(options: [.cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let n = W * H
        let real = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        let last = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        var mosh = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        var next = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        defer { real.deallocate(); last.deallocate(); mosh.deallocate(); next.deallocate() }
        let bw = (W + block - 1) / block, bh = (H + block - 1) / block
        var vectors = [Vec](repeating: Vec(x: 0, y: 0), count: bw * bh)
        var frozen: [Vec]?
        var previous: CVPixelBuffer?
        var moshing = false
        let end = start + length
        let keep = Float(1 - min(1, max(0, leak)))

        func upright(_ pb: CVPixelBuffer, w: Int, h: Int) -> CIImage {
            var img = CIImage(cvPixelBuffer: pb).oriented(orient)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            return img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
        }

        while let sample = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let t = pts.seconds
            let frame = upright(pb, w: W, h: H)
            ctx.render(frame, toBitmap: real, rowBytes: W * 4, bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .BGRA8, colorSpace: space)
            let small = smallBuffer(frame, w: fw, h: fh, ctx: ctx)

            if t >= start - 0.0005, t < end {
                if !moshing {
                    moshing = true
                    frozen = nil
                    if mode == .fromPrevious, let stuck {
                        let img = CIImage(cgImage: stuck)
                        let s = img.transformed(by: CGAffineTransform(scaleX: CGFloat(W) / img.extent.width, y: CGFloat(H) / img.extent.height))
                        ctx.render(s, toBitmap: mosh, rowBytes: W * 4, bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .BGRA8, colorSpace: space)
                    } else {
                        mosh.update(from: previous == nil ? real : last, count: n)
                    }
                }
                if let previous, let small, let flow = opticalFlow(from: previous, to: small) {
                    blockVectors(flow, into: &vectors, bw: bw, bh: bh, W: W, H: H, gain: Float(amount))
                    if mode == .bloom {
                        if frozen == nil, energy(vectors) > 0.6 * Float(amount) { frozen = vectors }
                        if let frozen { vectors = frozen }
                    }
                    warp(mosh, into: next, real: real, keep: keep, vectors: vectors, bw: bw, W: W, H: H)
                    swap(&mosh, &next)
                }
                try await append(mosh, at: pts, W: W, H: H, adaptor: adaptor, input: input)
            } else {
                moshing = false
                try await append(real, at: pts, W: W, H: H, adaptor: adaptor, input: input)
            }
            previous = small
            last.update(from: real, count: n)
            progress?(min(1, t / duration))
        }
        if reader.status == .failed { throw CompositionExport.ExportError.failed(reader.error?.localizedDescription ?? "Datamosh failed.") }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw CompositionExport.ExportError.failed(writer.error?.localizedDescription ?? "Datamosh failed.") }
        return out
    }

    private static func smallBuffer(_ img: CIImage, w: Int, h: Int, ctx: CIContext) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        let s = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
        ctx.render(s, to: pb)
        return pb
    }

    /// Per-pixel motion from `a` to `b`, in `a`'s pixels (two floats per pixel).
    private static func opticalFlow(from a: CVPixelBuffer, to b: CVPixelBuffer) -> CVPixelBuffer? {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: b, options: [:])
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        guard (try? VNImageRequestHandler(cvPixelBuffer: a, options: [:]).perform([request])) != nil,
              let obs = request.results?.first else { return nil }
        return obs.pixelBuffer
    }

    /// Averages the flow over each 16×16 block of the output frame, scaled to output pixels.
    private static func blockVectors(_ flow: CVPixelBuffer, into v: inout [Vec], bw: Int, bh: Int, W: Int, H: Int, gain: Float) {
        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(flow) else { return }
        let fw = CVPixelBufferGetWidth(flow), fh = CVPixelBufferGetHeight(flow)
        let row = CVPixelBufferGetBytesPerRow(flow)
        let sx = gain * Float(W) / Float(fw), sy = gain * Float(H) / Float(fh)
        for by in 0..<bh {
            let y0 = by * block * fh / H, y1 = max(y0 + 1, min(fh, (by + 1) * block * fh / H))
            for bx in 0..<bw {
                let x0 = bx * block * fw / W, x1 = max(x0 + 1, min(fw, (bx + 1) * block * fw / W))
                var dx: Float = 0, dy: Float = 0, c: Float = 0
                for y in y0..<min(y1, fh) {
                    let p = base.advanced(by: y * row).assumingMemoryBound(to: Float.self)
                    for x in x0..<min(x1, fw) { dx += p[x * 2]; dy += p[x * 2 + 1]; c += 1 }
                }
                v[by * bw + bx] = c > 0 ? Vec(x: dx / c * sx, y: dy / c * sy) : Vec(x: 0, y: 0)
            }
        }
    }

    private static func energy(_ v: [Vec]) -> Float {
        guard !v.isEmpty else { return 0 }
        return v.reduce(0) { $0 + abs($1.x) + abs($1.y) } / Float(v.count)
    }

    /// Each block of the new picture is copied from where its motion vector points in the old one.
    private static func warp(_ src: UnsafeMutablePointer<UInt32>, into dst: UnsafeMutablePointer<UInt32>, real: UnsafeMutablePointer<UInt32>,
                             keep: Float, vectors: [Vec], bw: Int, W: Int, H: Int) {
        let s = Ptr(p: src), d = Ptr(p: dst), r = Ptr(p: real)
        let k = UInt32(max(0, min(256, keep * 256)))
        vectors.withUnsafeBufferPointer { vb in
            let vp = vb.baseAddress!
            let vbox = UnsafePointerBox(p: vp)
            DispatchQueue.concurrentPerform(iterations: H) { y in
                let by = y / block
                for x in 0..<W {
                    let m = vbox.p[by * bw + x / block]
                    let sx = min(W - 1, max(0, x - Int(m.x.rounded())))
                    let sy = min(H - 1, max(0, y - Int(m.y.rounded())))
                    let moved = s.p[sy * W + sx]
                    d.p[y * W + x] = k >= 256 ? moved : mix(moved, r.p[y * W + x], k)
                }
            }
        }
    }

    private struct UnsafePointerBox: @unchecked Sendable { let p: UnsafePointer<Vec> }

    private static func mix(_ a: UInt32, _ b: UInt32, _ k: UInt32) -> UInt32 {
        let mask: UInt32 = 0x00FF00FF
        let j: UInt32 = 256 - k
        let a1: UInt32 = (a & mask) &* k, b1: UInt32 = (b & mask) &* j
        let a2: UInt32 = ((a >> 8) & mask) &* k, b2: UInt32 = ((b >> 8) & mask) &* j
        let rb: UInt32 = ((a1 &+ b1) >> 8) & mask
        let ga: UInt32 = ((a2 &+ b2) >> 8) & mask
        return rb | (ga << 8)
    }

    private static func append(_ pixels: UnsafeMutablePointer<UInt32>, at pts: CMTime, W: Int, H: Int,
                               adaptor: AVAssetWriterInputPixelBufferAdaptor, input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        guard let pool = adaptor.pixelBufferPool else { throw CompositionExport.ExportError.failed("Datamosh failed.") }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { throw CompositionExport.ExportError.failed("Datamosh failed.") }
        CVPixelBufferLockBaseAddress(pb, [])
        let row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        for y in 0..<H { memcpy(base.advanced(by: y * row), pixels.advanced(by: y * W), W * 4) }
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: pts)
    }
}
