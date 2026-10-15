// SPDX-License-Identifier: AGPL-3.0-only

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Foundation

/// ñü.ævätåřş styles for the local camera (on device). Matches `design/nu-avatars.md`.
enum AvatarStyle: String, CaseIterable, Identifiable, Sendable {
    case off
    case ink
    case toon
    case pixel
    case glass

    var id: String { rawValue }

    /// Shown in the call UI (lowercase house style).
    var label: String {
        switch self {
        case .off: "off"
        case .ink: "ink"
        case .toon: "toon"
        case .pixel: "pixel"
        case .glass: "glass"
        }
    }

    var symbol: String {
        switch self {
        case .off: "person.fill"
        case .ink: "pencil.tip"
        case .toon: "paintpalette.fill"
        case .pixel: "square.grid.3x3.fill"
        case .glass: "rectangle.on.rectangle.angled"
        }
    }
}

/// Applies a style to camera frames before encode. Nothing leaves the device.
final class AvatarStyler: @unchecked Sendable {
    private let lock = NSLock()
    private var style: AvatarStyle = .off
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize: (Int, Int) = (0, 0)

    func setStyle(_ s: AvatarStyle) {
        lock.withLock { style = s }
    }

    var current: AvatarStyle { lock.withLock { style } }

    /// Returns a new sample buffer when a style is on; otherwise the original.
    func process(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        let s = lock.withLock { style }
        guard s != .off, let src = CMSampleBufferGetImageBuffer(sample) else { return sample }
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard let dest = buffer(width: w, height: h) else { return sample }

        var image = CIImage(cvPixelBuffer: src)
        switch s {
        case .off:
            break
        case .ink:
            let mono = image.applyingFilter("CIPhotoEffectMono")
            let edges = mono.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 8.0])
            let invert = edges.applyingFilter("CIColorInvert")
            let soft = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.35,
                kCIInputContrastKey: 1.15,
            ])
            image = invert.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: soft])
        case .toon:
            image = image
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])
                .applyingFilter("CIColorPosterize", parameters: ["inputLevels": 6.0])
        case .pixel:
            image = image.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 12.0])
        case .glass:
            let blur = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.5])
            let cool = blur.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.85,
                kCIInputBrightnessKey: 0.04,
            ])
            image = cool.applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputBackgroundImageKey: image.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.7,
                ]),
            ])
        }

        ci.render(image, to: dest)
        return Self.wrap(dest, like: sample) ?? sample
    }

    private func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            poolSize = (width, height)
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
        }
        var buf: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf) == kCVReturnSuccess else { return nil }
        return buf
    }

    private static func wrap(_ image: CVPixelBuffer, like sample: CMSampleBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample)
        )
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: image,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &out
        )
        return out
    }
}
