// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreImage
import CoreText
import Foundation
import Vision

// MARK: - Plan

/// One clip drawn into one collage cell for a span of the timeline.
struct LayerSpec: @unchecked Sendable {
    let trackID: CMPersistentTrackID
    let cell: CGRect
    let clip: MomentClip
    let start: Double
    let duration: Double
    let orientation: CGImagePropertyOrientation
    let isFirst: Bool
    let isLast: Bool
    /// Seconds of extra media drawn under the next clip so a fade crosses into it instead of through the backdrop.
    var tail: Double = 0
}

struct StaticLayer: @unchecked Sendable {
    let overlay: MomentOverlay
    let image: CIImage
}

struct CaptionRender: @unchecked Sendable {
    let caption: MomentCaption
    let base: CIImage
    /// One image per word with that word highlighted (empty when not highlighting).
    let perWord: [CIImage]
}

/// Immutable description of everything drawn over the clips. Shared by every instruction.
final class RenderPlan: @unchecked Sendable {
    let canvas: CGSize
    let look: MomentLook
    let transition: MomentTransition
    let backdrop: CIColor
    let accent: CIColor
    let effects: [MomentEffect]
    let statics: [StaticLayer]
    let videoOverlays: [CMPersistentTrackID: MomentOverlay]
    let captions: [CaptionRender]
    let captionLook: CaptionLook

    init(canvas: CGSize, look: MomentLook, transition: MomentTransition, backdrop: CIColor, accent: CIColor,
         effects: [MomentEffect], statics: [StaticLayer], videoOverlays: [CMPersistentTrackID: MomentOverlay],
         captions: [CaptionRender], captionLook: CaptionLook) {
        self.canvas = canvas; self.look = look; self.transition = transition; self.backdrop = backdrop; self.accent = accent
        self.effects = effects; self.statics = statics; self.videoOverlays = videoOverlays; self.captions = captions
        self.captionLook = captionLook
    }

    var rect: CGRect { CGRect(origin: .zero, size: canvas) }
    var k: CGFloat { canvas.width / 1080 }
}

final class MomentInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [LayerSpec]
    let overlayTracks: [CMPersistentTrackID]
    let plan: RenderPlan

    init(timeRange: CMTimeRange, layers: [LayerSpec], overlayTracks: [CMPersistentTrackID], plan: RenderPlan) {
        self.timeRange = timeRange
        self.layers = layers
        self.overlayTracks = overlayTracks
        self.plan = plan
        let ids = Set(layers.map(\.trackID) + overlayTracks)
        self.requiredSourceTrackIDs = ids.isEmpty ? nil : ids.map { NSNumber(value: $0) }
        super.init()
    }
}

// MARK: - Compositor

private struct RequestBox: @unchecked Sendable { let request: AVAsynchronousVideoCompositionRequest }

/// Draws every frame for preview and export, so what you watch is the file you get.
final class MomentCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "nu.moments.compositor", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private let segmenter = PersonMasker()

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA], kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA], kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var supportsWideColorSourceFrames: Bool { false }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        let box = RequestBox(request: asyncVideoCompositionRequest)
        queue.async { [self] in
            let request = box.request
            guard let instruction = request.videoCompositionInstruction as? MomentInstruction,
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "nu.moments", code: 10, userInfo: [NSLocalizedDescriptionKey: "Frame could not be drawn."]))
                return
            }
            let plan = instruction.plan
            let t = request.compositionTime.seconds
            let layers: [(LayerSpec, CIImage?)] = instruction.layers.map { spec in
                (spec, request.sourceFrame(byTrackID: spec.trackID).map { CIImage(cvPixelBuffer: $0) })
            }
            let media: [(MomentOverlay, CIImage?)] = instruction.overlayTracks.compactMap { id in
                guard let o = plan.videoOverlays[id] else { return nil }
                return (o, request.sourceFrame(byTrackID: id).map { CIImage(cvPixelBuffer: $0) })
            }
            let image = FrameRenderer.render(time: t, layers: layers, videoOverlays: media, plan: plan, masker: segmenter)
            context.render(image, to: out, bounds: plan.rect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

/// Vision person segmentation, reused across frames on the compositor queue.
final class PersonMasker: @unchecked Sendable {
    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private let context = CIContext()
    private var buffer: CVPixelBuffer?

    /// A mask the size of `image` (white = person), or nil when nobody is found.
    func mask(for image: CIImage) -> CIImage? {
        let ext = image.extent.integral
        guard ext.width > 1, ext.height > 1 else { return nil }
        let w = Int(ext.width), h = Int(ext.height)
        if buffer == nil || CVPixelBufferGetWidth(buffer!) != w || CVPixelBufferGetHeight(buffer!) != h {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            buffer = pb
        }
        guard let buffer else { return nil }
        context.render(image.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY)), to: buffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first else { return nil }
        let m = CIImage(cvPixelBuffer: obs.pixelBuffer)
        return m.transformed(by: CGAffineTransform(scaleX: ext.width / m.extent.width, y: ext.height / m.extent.height))
            .transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
    }
}

// MARK: - Frame renderer

enum FrameRenderer {
    static func render(time t: Double, layers: [(LayerSpec, CIImage?)], videoOverlays: [(MomentOverlay, CIImage?)],
                       plan: RenderPlan, masker: PersonMasker?) -> CIImage {
        let rect = plan.rect
        var canvas = CIImage(color: plan.backdrop).cropped(to: rect)

        for (spec, frame) in layers {
            guard let frame else { continue }
            var src = frame.oriented(spec.orientation)
            src = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
            src = Adjust.apply(spec.clip.adjust, to: src, k: plan.k)
            let cell = ciRect(spec.cell, in: plan.canvas)
            let placed = place(src, spec: spec, cell: cell, t: t, plan: plan, masker: masker)
            canvas = placed.composited(over: canvas)
        }
        canvas = canvas.cropped(to: rect)
        canvas = LookFilter.apply(plan.look, to: canvas, canvas: plan.canvas)

        for e in plan.effects {
            let start = e.wholeTimeline ? 0 : e.start
            let end = e.wholeTimeline ? Double.greatestFiniteMagnitude : e.start + e.duration
            guard t >= start, t < end else { continue }
            canvas = Effects.apply(e, to: canvas, localTime: t - start, progress: e.wholeTimeline ? 0 : (t - start) / max(0.01, e.duration), plan: plan)
        }

        for (o, frame) in videoOverlays {
            guard let frame, t >= o.start, t < o.start + o.duration else { continue }
            var img = frame
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            img = Keying.apply(o.key, to: img, masker: masker)
            canvas = Overlays.place(img, overlay: o, t: t, plan: plan).composited(over: canvas)
        }
        for s in plan.statics {
            let o = s.overlay
            guard t >= o.start, t < o.start + o.duration else { continue }
            var img = s.image
            if o.kind == .media { img = Keying.apply(o.key, to: img, masker: masker) }
            canvas = Overlays.place(img, overlay: o, t: t, plan: plan).composited(over: canvas)
        }
        for c in plan.captions {
            let cap = c.caption
            guard t >= cap.start, t < cap.start + cap.duration else { continue }
            var img = c.base
            if !c.perWord.isEmpty, let i = cap.words.lastIndex(where: { t >= $0.start }) { img = c.perWord[min(i, c.perWord.count - 1)] }
            canvas = Captions.place(img, caption: cap, t: t, plan: plan).composited(over: canvas)
        }
        return canvas.cropped(to: rect)
    }

    /// 0…1 top-left rect to Core Image (bottom-left) pixels.
    static func ciRect(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    private static func place(_ src: CIImage, spec: LayerSpec, cell: CGRect, t: Double, plan: RenderPlan, masker: PersonMasker?) -> CIImage {
        let clip = spec.clip
        let iw = max(1, src.extent.width), ih = max(1, src.extent.height)
        let fill = max(cell.width / iw, cell.height / ih)
        let fit = min(cell.width / iw, cell.height / ih)
        let local = t - spec.start
        let p = min(1, max(0, local / max(0.01, spec.duration)))

        var mScale = 1.0, mx = 0.0, my = 0.0
        switch clip.motion {
        case .none: break
        case .zoomIn: mScale = 1 + 0.14 * p
        case .zoomOut: mScale = 1.14 - 0.14 * p
        case .panLeft: mScale = 1.14; mx = (0.5 - p) * 0.12
        case .panRight: mScale = 1.14; mx = (p - 0.5) * 0.12
        case .panUp: mScale = 1.14; my = (p - 0.5) * 0.12
        case .panDown: mScale = 1.14; my = (0.5 - p) * 0.12
        case .drift: mScale = 1.06 + 0.07 * p; mx = (p - 0.5) * 0.05; my = (0.5 - p) * 0.04
        }

        func positioned(_ img: CIImage, base: CGFloat) -> CIImage {
            let s = base * mScale
            let w = iw * s, h = ih * s
            let x = cell.midX - w / 2 + mx * cell.width
            let y = cell.midY - h / 2 + my * cell.height
            return img.transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: x, y: y)))
        }

        var layer: CIImage
        switch clip.background {
        case .fill:
            layer = positioned(src, base: fill)
        case .fit:
            layer = positioned(src, base: fit)
        case .blurFill:
            let back = positioned(src.clampedToExtent().applyingGaussianBlur(sigma: 28 * plan.k).cropped(to: src.extent), base: fill)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 0.9])
            layer = positioned(src, base: fit).composited(over: back)
        case .cutout:
            if let m = masker?.mask(for: src) {
                let person = src.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m])
                layer = positioned(person, base: fill)
            } else {
                layer = positioned(src, base: fill)
            }
        case .greenScreen:
            layer = positioned(Keying.chroma(src), base: fill)
        }

        if let k = Keyframes.clip(clip.keyframes, at: local) {
            let c = CGPoint(x: cell.midX, y: cell.midY)
            layer = layer.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: k.zoom, y: k.zoom))
                .concatenating(CGAffineTransform(rotationAngle: -k.rotation * .pi / 180))
                .concatenating(CGAffineTransform(translationX: c.x + k.x * cell.width, y: c.y - k.y * cell.height)))
            if k.opacity < 0.999 {
                layer = layer.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, k.opacity))])
            }
        }
        layer = Anim.applyClip(layer, clip: clip, local: local, duration: spec.duration, cell: cell, plan: plan, isFirst: spec.isFirst, isLast: spec.isLast || spec.tail > 0)
        return layer.cropped(to: cell)
    }
}

// MARK: - Adjustments

enum Adjust {
    static func apply(_ a: ClipAdjust, to image: CIImage, k: CGFloat) -> CIImage {
        guard !a.isNeutral else { return image }
        var out = image
        let ext = image.extent
        if a.exposure != 0 || a.relight > 0 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure + a.relight * 0.25])
        }
        if a.contrast != 1 || a.saturation != 1 {
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation])
        }
        if a.warmth != 0 {
            out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                                                                        "inputTargetNeutral": CIVector(x: 6500 + 2600 * a.warmth, y: 0)])
        }
        if a.relight > 0 {
            out = out.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 0.9 * a.relight, "inputHighlightAmount": 1 - 0.25 * a.relight])
            let light = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: ext.midX, y: ext.minY + ext.height * 0.62),
                "inputRadius0": ext.width * 0.05, "inputRadius1": ext.width * 0.75,
                "inputColor0": CIColor(red: 1, green: 0.96, blue: 0.9, alpha: 0.28 * a.relight),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)])?.outputImage?.cropped(to: ext)
            if let light { out = light.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: out]) }
        }
        if a.sharpen > 0 {
            out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpen * 1.5])
        }
        return out.cropped(to: ext)
    }
}

// MARK: - Keying

enum Keying {
    static func apply(_ key: MediaKey, to image: CIImage, masker: PersonMasker?) -> CIImage {
        switch key {
        case .none: return image
        case .greenScreen: return chroma(image)
        case .cutout:
            guard let m = masker?.mask(for: image) else { return image }
            return image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m])
        }
    }

    static func chroma(_ image: CIImage) -> CIImage {
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(64, forKey: "inputCubeDimension")
        f.setValue(cube, forKey: "inputCubeData")
        f.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        return f.outputImage ?? image
    }

    private static let cube: Data = {
        let n = 64
        var c = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for z in 0..<n {
            let b = Float(z) / Float(n - 1)
            for y in 0..<n {
                let g = Float(y) / Float(n - 1)
                for x in 0..<n {
                    let r = Float(x) / Float(n - 1)
                    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
                    var h: Float = 0
                    if d > 0 {
                        if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
                        else if mx == g { h = (b - r) / d + 2 }
                        else { h = (r - g) / d + 4 }
                        h /= 6; if h < 0 { h += 1 }
                    }
                    let s = mx > 0 ? d / mx : 0
                    let green = h > 0.2 && h < 0.5 && s > 0.28 && mx > 0.18
                    let a: Float = green ? 0 : 1
                    c[i] = r * a; c[i + 1] = g * a; c[i + 2] = b * a; c[i + 3] = a
                    i += 4
                }
            }
        }
        return c.withUnsafeBufferPointer { Data(buffer: $0) }
    }()
}

// MARK: - Animation

struct AnimState {
    var opacity = 1.0
    var scale = 1.0
    var dx = 0.0
    var dy = 0.0
    var rotation = 0.0
    var blur = 0.0
    var exposure = 0.0
    /// 0…1 left-to-right reveal for typewriter / wipe.
    var reveal = 1.0
}

enum Anim {
    static let length = 0.38

    /// State for an in (u from 0 to 1) or out (u from 1 to 0) animation; u = 1 means fully shown.
    static func state(_ a: MotionAnim, u raw: Double, outgoing: Bool) -> AnimState {
        var s = AnimState()
        let u = min(1, max(0, raw))
        let e = 1 - pow(1 - u, 3)
        switch a {
        case .none: break
        case .fade: s.opacity = u
        case .pop: s.scale = outgoing ? 0.6 + 0.4 * e : (u < 1 ? 0.6 + 0.55 * e - 0.15 * max(0, e - 0.7) / 0.3 : 1); s.opacity = min(1, u * 2)
        case .zoomIn: s.scale = 0.4 + 0.6 * e; s.opacity = u
        case .zoomOut: s.scale = 1.6 - 0.6 * e; s.opacity = u
        case .slideUp: s.dy = -(1 - e) * 0.25; s.opacity = u
        case .slideDown: s.dy = (1 - e) * 0.25; s.opacity = u
        case .slideLeft: s.dx = (1 - e) * 0.35; s.opacity = u
        case .slideRight: s.dx = -(1 - e) * 0.35; s.opacity = u
        case .typewriter: s.reveal = u
        case .bounce:
            let b = u < 1 ? abs(sin(u * .pi * 2.5)) * (1 - u) : 0
            s.dy = -b * 0.12; s.opacity = min(1, u * 3)
        case .spin: s.rotation = (1 - e) * .pi * 1.5; s.scale = 0.5 + 0.5 * e; s.opacity = u
        case .blur: s.blur = (1 - u) * 30; s.opacity = u
        case .flash: s.exposure = (1 - u) * 2.5
        case .whip: s.dx = (1 - e) * (outgoing ? -0.6 : 0.6); s.blur = (1 - u) * 24
        case .drop: s.dy = (1 - e) * 0.5; s.rotation = (1 - e) * 0.25; s.opacity = min(1, u * 2)
        }
        return s
    }

    /// Applies a state around `center`; dx/dy are fractions of `span`.
    static func apply(_ s: AnimState, to img: CIImage, center: CGPoint, span: CGSize) -> CIImage {
        var out = img
        if s.reveal < 1 {
            let e = out.extent
            out = out.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width * s.reveal, height: e.height))
        }
        if s.blur > 0.5 { out = out.clampedToExtent().applyingGaussianBlur(sigma: s.blur).cropped(to: out.extent.insetBy(dx: -s.blur * 2, dy: -s.blur * 2)) }
        if s.exposure > 0.01 { out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure]) }
        if s.scale != 1 || s.rotation != 0 {
            let tr = CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(rotationAngle: s.rotation))
                .concatenating(CGAffineTransform(scaleX: s.scale, y: s.scale))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            out = out.transformed(by: tr)
        }
        if s.dx != 0 || s.dy != 0 {
            out = out.transformed(by: CGAffineTransform(translationX: s.dx * span.width, y: -s.dy * span.height))
        }
        if s.opacity < 0.999 {
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, s.opacity))])
        }
        return out
    }

    static func applyClip(_ img: CIImage, clip: MomentClip, local: Double, duration: Double, cell: CGRect,
                          plan: RenderPlan, isFirst: Bool, isLast: Bool) -> CIImage {
        var out = img
        let center = CGPoint(x: cell.midX, y: cell.midY)
        let len = min(length, duration / 3)
        if clip.animIn != .none, local < len {
            out = apply(state(clip.animIn, u: local / len, outgoing: false), to: out, center: center, span: cell.size)
        }
        if clip.animOut != .none, duration - local < len {
            out = apply(state(clip.animOut, u: (duration - local) / len, outgoing: true), to: out, center: center, span: cell.size)
        }
        // Template transition at the joins between clips.
        let tl = min(0.3, duration / 3)
        let toIn = isFirst ? 1 : local / tl
        let toOut = isLast ? 1 : (duration - local) / tl
        let u = min(1, max(0, min(toIn, toOut)))
        guard u < 1 else { return out }
        let incoming = toIn < toOut
        switch plan.transition {
        case .cut: break
        case .fade: out = apply(AnimState(opacity: u), to: out, center: center, span: cell.size)
        case .dip: out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(max(u, 0.04))])
        case .flash: out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: (1 - u) * 3])
        case .whip: out = apply(state(.whip, u: u, outgoing: !incoming), to: out, center: center, span: cell.size)
        case .zoom: out = apply(AnimState(scale: incoming ? 1.35 - 0.35 * u : 1 + 0.35 * (1 - u), blur: (1 - u) * 14), to: out, center: center, span: cell.size)
        case .slide: out = apply(AnimState(dx: incoming ? (1 - u) * 1.0 : -(1 - u) * 1.0), to: out, center: center, span: cell.size)
        }
        return out
    }
}

// MARK: - Overlays and captions

enum Overlays {
    static func place(_ image: CIImage, overlay o: MomentOverlay, t: Double, plan: RenderPlan) -> CIImage {
        let W = plan.canvas.width, H = plan.canvas.height
        var img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let iw = max(1, img.extent.width)
        let k = Keyframes.overlay(o, at: t - o.start)
        var s = k.scale
        if o.kind == .media || (o.kind == .sticker && o.mediaName != nil) { s *= (o.widthFrac * W) / iw }
        if o.kind == .drawing { s = W / iw }
        let center = CGPoint(x: k.center.x * W, y: (1 - k.center.y) * H)
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.width / 2, y: -img.extent.height / 2)
            .concatenating(CGAffineTransform(rotationAngle: -k.rotation * .pi / 180))
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        let local = t - o.start
        let len = min(Anim.length, o.duration / 3)
        if o.animIn != .none, local < len { img = Anim.apply(Anim.state(o.animIn, u: local / len, outgoing: false), to: img, center: center, span: plan.canvas) }
        if o.animOut != .none, o.duration - local < len { img = Anim.apply(Anim.state(o.animOut, u: (o.duration - local) / len, outgoing: true), to: img, center: center, span: plan.canvas) }
        if k.opacity < 0.999 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, k.opacity))])
        }
        return img
    }
}

enum Captions {
    static func place(_ image: CIImage, caption c: MomentCaption, t: Double, plan: RenderPlan) -> CIImage {
        let W = plan.canvas.width, H = plan.canvas.height
        let center = CGPoint(x: W / 2, y: (1 - plan.captionLook.position.y) * H)
        var img = image.transformed(by: CGAffineTransform(translationX: center.x - image.extent.width / 2 - image.extent.minX,
                                                          y: center.y - image.extent.height / 2 - image.extent.minY))
        let local = t - c.start
        let len = min(0.22, c.duration / 3)
        let inAnim: MotionAnim
        switch c.style {
        case .pop: inAnim = .pop
        case .typewriter: inAnim = .typewriter
        case .stamp: inAnim = .zoomOut
        case .bold: inAnim = .slideUp
        case .soft, .outline, .neon, .plain: inAnim = .fade
        }
        let typeLen = c.style == .typewriter ? min(c.duration * 0.6, 0.06 * Double(c.text.count)) : len
        if local < typeLen { img = Anim.apply(Anim.state(inAnim, u: local / typeLen, outgoing: false), to: img, center: center, span: plan.canvas) }
        if c.duration - local < len { img = Anim.apply(Anim.state(.fade, u: (c.duration - local) / len, outgoing: true), to: img, center: center, span: plan.canvas) }
        return img
    }
}

// MARK: - Text rasterising (Core Text, same on iPhone and Mac)

enum TextRaster {
    static func font(_ f: TextFont, size: CGFloat) -> CTFont {
        switch f {
        case .sans: return CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        case .rounded: return CTFontCreateWithName("ArialRoundedMTBold" as CFString, size, nil)
        case .serif: return CTFontCreateWithName("TimesNewRomanPS-BoldMT" as CFString, size, nil)
        case .mono: return CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        default: return CTFontCreateWithName((f.postScript ?? "Helvetica-Bold") as CFString, size, nil)
        }
    }

    /// Text in a box. `highlight` colours the word at that index.
    static func image(text: String, font f: TextFont, size: CGFloat, color: CGColor, box: CGColor?, outline: Bool,
                      maxWidth: CGFloat, highlight: Int? = nil, highlightColor: CGColor? = nil, glow: CGColor? = nil) -> CIImage? {
        guard !text.isEmpty else { return nil }
        let ctf = font(f, size: size)
        let para: CTParagraphStyle = {
            var align = CTTextAlignment.center
            return withUnsafeBytes(of: &align) { ptr in
                var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ptr.baseAddress!)
                return CTParagraphStyleCreate(&setting, 1)
            }
        }()
        let attr = NSMutableAttributedString(string: text)
        let all = NSRange(location: 0, length: (text as NSString).length)
        attr.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: ctf, range: all)
        attr.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color, range: all)
        attr.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: para, range: all)
        if outline {
            attr.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), value: CGColor(gray: 0, alpha: 1), range: all)
            attr.addAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), value: -6.0, range: all)
        }
        if let highlight, let highlightColor {
            var idx = 0
            (text as NSString).enumerateSubstrings(in: all, options: .byWords) { _, r, _, stop in
                if idx == highlight {
                    attr.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: highlightColor, range: r)
                    stop.pointee = true
                }
                idx += 1
            }
        }
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let pad = box == nil ? size * 0.25 : size * 0.42
        let w = ceil(fit.width + pad * 2), h = ceil(fit.height + pad * 1.4)
        guard w > 2, h > 2, let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let box {
            ctx.setFillColor(box)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: size * 0.36, cornerHeight: size * 0.36, transform: nil))
            ctx.fillPath()
        } else {
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.04), blur: size * 0.18, color: glow ?? CGColor(gray: 0, alpha: 0.55))
        }
        let path = CGPath(rect: CGRect(x: pad, y: pad * 0.7, width: ceil(fit.width), height: ceil(fit.height)), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    static func overlay(_ o: MomentOverlay, canvasWidth: CGFloat) -> CIImage? {
        let k = canvasWidth / 1080
        if o.kind == .sticker, o.mediaName == nil {
            return image(text: o.text, font: .sans, size: o.fontSize * 1.6 * k, color: CGColor(gray: 1, alpha: 1), box: nil, outline: false,
                         maxWidth: canvasWidth, glow: CGColor(gray: 0, alpha: 0.25))
        }
        return image(text: o.text, font: o.font, size: o.fontSize * k, color: Hex.cg(o.colorHex), box: o.boxHex.map(Hex.cg),
                     outline: o.outline, maxWidth: canvasWidth * 0.86)
    }

    static func caption(_ c: MomentCaption, look: CaptionLook, accent: CGColor, canvasWidth: CGFloat, highlight: Int? = nil) -> CIImage? {
        let k = canvasWidth / 1080
        let size = look.size * k
        let color = Hex.cg(look.colorHex)
        let hl = Hex.cg(look.highlightHex)
        switch c.style {
        case .pop: return image(text: c.text, font: look.font, size: size, color: color, box: accent.copy(alpha: 0.9), outline: false, maxWidth: canvasWidth * 0.84, highlight: highlight, highlightColor: CGColor(gray: 0.05, alpha: 1))
        case .typewriter: return image(text: c.text, font: .typewriter, size: size, color: color, box: CGColor(gray: 0.06, alpha: 0.78), outline: false, maxWidth: canvasWidth * 0.84, highlight: highlight, highlightColor: hl)
        case .soft: return image(text: c.text, font: look.font, size: size, color: color, box: CGColor(gray: 1, alpha: 0.22), outline: false, maxWidth: canvasWidth * 0.84, highlight: highlight, highlightColor: hl)
        case .stamp: return image(text: c.text.uppercased(), font: .condensed, size: size, color: color, box: CGColor(gray: 0.04, alpha: 0.92), outline: false, maxWidth: canvasWidth * 0.84, highlight: highlight, highlightColor: hl)
        case .bold: return image(text: c.text.uppercased(), font: .condensed, size: size * 1.25, color: color, box: nil, outline: true, maxWidth: canvasWidth * 0.86, highlight: highlight, highlightColor: hl)
        case .outline: return image(text: c.text, font: look.font, size: size * 1.1, color: color, box: nil, outline: true, maxWidth: canvasWidth * 0.86, highlight: highlight, highlightColor: hl)
        case .neon: return image(text: c.text, font: .rounded, size: size * 1.1, color: hl, box: nil, outline: false, maxWidth: canvasWidth * 0.86, highlight: highlight, highlightColor: color, glow: hl)
        case .plain: return image(text: c.text, font: look.font, size: size, color: color, box: nil, outline: false, maxWidth: canvasWidth * 0.86, highlight: highlight, highlightColor: hl)
        }
    }
}

// MARK: - Looks

/// Shared Core Image look chain (video frames, stills and carousel slides).
enum LookFilter {
    static func apply(_ look: MomentLook, to image: CIImage, canvas: CGSize) -> CIImage {
        var out = image
        func run(_ name: String, _ params: [String: Any] = [:]) { out = out.applyingFilter(name, parameters: params) }
        switch look {
        case .natural: break
        case .film:
            run("CISepiaTone", [kCIInputIntensityKey: 0.35]); run("CIColorControls", [kCIInputSaturationKey: 1.15, kCIInputContrastKey: 1.06])
            run("CIVignette", [kCIInputIntensityKey: 0.7, kCIInputRadiusKey: 1.2])
        case .printed: run("CIColorControls", [kCIInputSaturationKey: 0.75, kCIInputContrastKey: 1.22, kCIInputBrightnessKey: 0.02])
        case .haze:
            run("CIColorControls", [kCIInputSaturationKey: 0.82, kCIInputBrightnessKey: 0.07, kCIInputContrastKey: 0.94])
            out = out.clampedToExtent().applyingGaussianBlur(sigma: 1.1)
        case .digitalPop: run("CIColorControls", [kCIInputSaturationKey: 1.5, kCIInputContrastKey: 1.1])
        case .vhs: run("CIHueAdjust", [kCIInputAngleKey: 0.3]); run("CIColorControls", [kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.05])
        case .mono: run("CIPhotoEffectMono")
        case .noir: run("CIPhotoEffectNoir")
        case .chrome: run("CIPhotoEffectChrome")
        case .faded: run("CIPhotoEffectFade")
        case .instant: run("CIPhotoEffectInstant")
        case .warm:
            run("CITemperatureAndTint", ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8200, y: 0)])
            run("CIColorControls", [kCIInputSaturationKey: 1.08])
        case .cool:
            run("CITemperatureAndTint", ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 4800, y: 0)])
            run("CIColorControls", [kCIInputContrastKey: 1.06])
        case .tealOrange:
            let toned = out.applyingFilter("CIFalseColor", parameters: ["inputColor0": CIColor(red: 0.0, green: 0.28, blue: 0.35), "inputColor1": CIColor(red: 1, green: 0.72, blue: 0.45)])
            out = toned.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: out, kCIInputTimeKey: 0.78])
            run("CIColorControls", [kCIInputSaturationKey: 1.15, kCIInputContrastKey: 1.08])
        case .pastel:
            run("CIColorControls", [kCIInputSaturationKey: 0.72, kCIInputBrightnessKey: 0.06, kCIInputContrastKey: 0.88])
            run("CITemperatureAndTint", ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6900, y: 18)])
        case .matte:
            run("CIToneCurve", ["inputPoint0": CIVector(x: 0, y: 0.09), "inputPoint1": CIVector(x: 0.25, y: 0.26), "inputPoint2": CIVector(x: 0.5, y: 0.5),
                                "inputPoint3": CIVector(x: 0.75, y: 0.74), "inputPoint4": CIVector(x: 1, y: 0.94)])
            run("CIColorControls", [kCIInputSaturationKey: 0.88])
        }
        return out.cropped(to: CGRect(origin: .zero, size: canvas))
    }
}
