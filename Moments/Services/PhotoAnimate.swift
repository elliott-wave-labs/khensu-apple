// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreImage
import CoreML
import Foundation
import ImageIO
import Vision

/// Relative depth, 1 = nearest, row-major, top row first.
struct DepthField: Sendable {
    let w: Int
    let h: Int
    let v: [Float]
}

/// Depth for a photo, all on the device: the photo's own depth (Portrait), else Depth Anything V2 Small (Core ML),
/// else the lifted subject in front of a floor-to-sky gradient.
enum DepthMap {
    enum Source: String, Sendable { case embedded = "the photo's own depth", model = "on-device depth model", subject = "subject cutout" }

    nonisolated(unsafe) private static let model: VNCoreMLModel? = {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU
        if let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16P6", withExtension: "mlmodelc"),
           let m = try? MLModel(contentsOf: url, configuration: cfg) { return try? VNCoreMLModel(for: m) }
        if let path = ProcessInfo.processInfo.environment["MOMENTS_DEPTH_MODEL"],
           let compiled = try? MLModel.compileModel(at: URL(fileURLWithPath: path)),
           let m = try? MLModel(contentsOf: compiled, configuration: cfg) { return try? VNCoreMLModel(for: m) }
        return nil
    }()

    static func estimate(url: URL, image cg: CGImage, width w: Int, height h: Int) -> (DepthField, Source) {
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        if let d = embedded(url: url), let f = field(from: d, w: w, h: h, ctx: ctx) { return (f, .embedded) }
        if let model {
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill
            if (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil,
               let obs = request.results?.first as? VNPixelBufferObservation,
               let f = field(from: CIImage(cvPixelBuffer: obs.pixelBuffer), w: w, h: h, ctx: ctx) { return (f, .model) }
        }
        return (subject(cg, w: w, h: h, ctx: ctx), .subject)
    }

    private static func embedded(url: URL) -> CIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeDisparity)
            ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeDepth)
        guard let info = info as? [AnyHashable: Any], var depth = try? AVDepthData(fromDictionaryRepresentation: info) else { return nil }
        if depth.depthDataType != kCVPixelFormatType_DisparityFloat32 { depth = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        if let raw = props?[kCGImagePropertyOrientation] as? UInt32, let o = CGImagePropertyOrientation(rawValue: raw) {
            depth = depth.applyingExifOrientation(o)
        }
        return CIImage(cvPixelBuffer: depth.depthDataMap)
    }

    /// Resizes any one-channel depth image to w×h floats, smooths it, and normalises to 0…1 (2nd–98th percentile).
    private static func field(from img: CIImage, w: Int, h: Int, ctx: CIContext) -> DepthField? {
        let e = img.extent
        guard e.width > 1, e.height > 1 else { return nil }
        let scaled = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
            .transformed(by: CGAffineTransform(translationX: -e.minX * CGFloat(w) / e.width, y: -e.minY * CGFloat(h) / e.height))
        let smooth = scaled.clampedToExtent().applyingGaussianBlur(sigma: Double(max(w, h)) / 400).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        var v = [Float](repeating: 0, count: w * h)
        v.withUnsafeMutableBytes { buf in
            ctx.render(smooth, toBitmap: buf.baseAddress!, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .Rf, colorSpace: nil)
        }
        let finite = v.filter(\.isFinite).sorted()
        guard finite.count > 16 else { return nil }
        let lo = finite[finite.count * 2 / 100], hi = finite[finite.count * 98 / 100]
        guard hi - lo > 1e-6 else { return nil }
        let r = 1 / (hi - lo)
        for i in v.indices { v[i] = v[i].isFinite ? min(1, max(0, (v[i] - lo) * r)) : 0 }
        return DepthField(w: w, h: h, v: v)
    }

    private static func subject(_ cg: CGImage, w: Int, h: Int, ctx: CIContext) -> DepthField {
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h { let g = Float(y) / Float(max(1, h - 1)) * 0.3; for x in 0..<w { v[y * w + x] = g } }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        if (try? handler.perform([request])) != nil, let obs = request.results?.first, !obs.allInstances.isEmpty,
           let mask = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler),
           let m = field(from: CIImage(cvPixelBuffer: mask), w: w, h: h, ctx: ctx) {
            for i in v.indices { v[i] = max(v[i], 0.35 + 0.6 * m.v[i]) }
        }
        return DepthField(w: w, h: h, v: v)
    }
}

/// Turns a still photo into a short 3D camera move: near things move more than far things.
enum PhotoAnimate {
    enum Path: String, CaseIterable, Identifiable, Codable, Sendable {
        case pushIn, pullOut, sway, orbit, rise, vertigo
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pushIn: "Push in"; case .pullOut: "Pull out"; case .sway: "Sway"; case .orbit: "Orbit"; case .rise: "Rise"; case .vertigo: "Vertigo"
            }
        }
    }

    struct Result: Sendable { let url: URL; let duration: Double; let depth: DepthMap.Source }

    static func render(photo url: URL, path: Path, seconds: Double, strength: Double,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try await run(url: url, path: path, seconds: seconds, strength: strength, progress: progress)
        }.value
    }

    private struct Ptr<T>: @unchecked Sendable { let p: UnsafeMutablePointer<T> }
    private struct CPtr<T>: @unchecked Sendable { let p: UnsafePointer<T> }

    private static func run(url: URL, path: Path, seconds: Double, strength: Double,
                            progress: (@Sendable (Double) -> Void)?) async throws -> Result {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 1920] as CFDictionary) else {
            throw CompositionExport.ExportError.failed("That photo could not be read.")
        }
        let W = cg.width & ~1, H = cg.height & ~1
        guard W >= 64, H >= 64 else { throw CompositionExport.ExportError.failed("That photo is too small to animate.") }

        var pixels = [UInt8](repeating: 0, count: W * H * 4)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        let (depth, source) = DepthMap.estimate(url: url, image: cg, width: W, height: H)

        let out = MediaImport.mediaDir.appendingPathComponent("animated-\(path.rawValue)-\(UUID().uuidString.prefix(6)).mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: W, AVVideoHeightKey: H])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw CompositionExport.ExportError.failed(writer.error?.localizedDescription ?? "Animation failed.") }
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        let frames = max(2, Int(seconds * Double(fps)))
        let A = min(1, max(0.1, strength))
        let dims = Float(min(W, H))

        let srcMem = UnsafeMutablePointer<UInt8>.allocate(capacity: pixels.count)
        srcMem.initialize(from: pixels, count: pixels.count)
        let depthMem = UnsafeMutablePointer<Float>.allocate(capacity: depth.v.count)
        depthMem.initialize(from: depth.v, count: depth.v.count)
        defer { srcMem.deallocate(); depthMem.deallocate() }
        let sp = CPtr(p: UnsafePointer(srcMem)), dp = CPtr(p: UnsafePointer(depthMem))

        for f in 0..<frames {
            let cam = camera(path, u: Double(f) / Double(frames - 1), strength: A, dims: dims)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw CompositionExport.ExportError.failed("Animation failed.") }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { throw CompositionExport.ExportError.failed("Animation failed.") }
            CVPixelBufferLockBaseAddress(pb, [])
            let rowBytes = CVPixelBufferGetBytesPerRow(pb)
            let op = Ptr(p: CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self))
            DispatchQueue.concurrentPerform(iterations: H) { y in
                warpRow(y, src: sp.p, depth: dp.p, out: op.p.advanced(by: y * rowBytes), W: W, H: H, cam: cam)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
            progress?(Double(f + 1) / Double(frames))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw CompositionExport.ExportError.failed(writer.error?.localizedDescription ?? "Animation failed.") }
        return Result(url: out, duration: Double(frames) / Double(fps), depth: source)
    }

    private struct Camera: Sendable { let tx: Float; let ty: Float; let dolly: Float; let focus: Float; let zoom: Float }

    private static func camera(_ path: Path, u: Double, strength A: Double, dims: Float) -> Camera {
        let e = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
        var tx = 0.0, ty = 0.0, dolly = 0.0, focus = 0.5, zoom = 1.1
        switch path {
        case .pushIn: dolly = 0.22 * A * e; focus = 0; zoom = 1.06
        case .pullOut: dolly = 0.22 * A * (1 - e); focus = 0; zoom = 1.06
        case .sway: tx = 0.045 * A * sin(2 * .pi * u); dolly = 0.02 * A
        case .orbit:
            tx = 0.04 * A * sin(2 * .pi * u)
            ty = 0.0125 * A * cos(2 * .pi * u)
            dolly = 0.04 * A
        case .rise: ty = 0.1 * A * (e - 0.5); dolly = 0.03 * A * e
        case .vertigo: dolly = -0.3 * A * e; focus = 0.85; zoom = 1.08
        }
        return Camera(tx: Float(tx) * dims, ty: Float(ty) * dims, dolly: Float(dolly), focus: Float(focus), zoom: Float(zoom))
    }

    /// Backward warp of one output row: find where each pixel came from given its depth (three fixed-point steps).
    private static func warpRow(_ y: Int, src s: UnsafePointer<UInt8>, depth d: UnsafePointer<Float>, out o: UnsafeMutablePointer<UInt8>,
                                W: Int, H: Int, cam: Camera) {
        let cx = Float(W) / 2, cy = Float(H) / 2
        let maxX = Float(W) - 1.001, maxY = Float(H) - 1.001
        let qy = Float(y) - cy
        for x in 0..<W {
            let qx = Float(x) - cx
            var dd = d[y * W + x]
            var sx: Float = 0
            var sy: Float = 0
            for _ in 0..<3 {
                let rel = dd - cam.focus
                let m = cam.zoom * (1 + cam.dolly * rel)
                sx = (qx - cam.tx * rel) / m + cx
                sy = (qy - cam.ty * rel) / m + cy
                let xi = min(W - 1, max(0, Int(sx)))
                let yi = min(H - 1, max(0, Int(sy)))
                dd = d[yi * W + xi]
            }
            sx = min(maxX, max(0, sx))
            sy = min(maxY, max(0, sy))
            let x0 = Int(sx), y0 = Int(sy)
            let fx = sx - Float(x0), fy = sy - Float(y0)
            let i00 = (y0 * W + x0) * 4
            let i10 = i00 + 4
            let i01 = i00 + W * 4
            let i11 = i01 + 4
            let w00 = (1 - fx) * (1 - fy)
            let w10 = fx * (1 - fy)
            let w01 = (1 - fx) * fy
            let w11 = fx * fy
            let oi = x * 4
            for c in 0..<4 {
                var v = Float(s[i00 + c]) * w00
                v += Float(s[i10 + c]) * w10
                v += Float(s[i01 + c]) * w01
                v += Float(s[i11 + c]) * w11
                o[oi + c] = UInt8(min(255, max(0, v + 0.5)))
            }
        }
    }
}
