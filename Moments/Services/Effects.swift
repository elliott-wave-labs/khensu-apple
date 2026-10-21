// SPDX-License-Identifier: AGPL-3.0-only

import CoreImage
import Foundation

/// Every timeline effect, drawn with Core Image on the device.
enum Effects {
    static func apply(_ e: MomentEffect, to image: CIImage, localTime lt: Double, progress u: Double, plan: RenderPlan) -> CIImage {
        let rect = plan.rect
        let W = rect.width, H = rect.height
        let k = plan.k
        let i = max(0, min(1, e.intensity))
        let sp = max(0.1, e.speed)
        let c = CIVector(x: W / 2, y: H / 2)
        var out = image

        func mix(_ filtered: CIImage, _ amount: Double) -> CIImage {
            filtered.cropped(to: rect).applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: 1 - amount])
        }
        func scaled(_ s: Double, rotate: Double = 0, dx: Double = 0, dy: Double = 0) -> CIImage {
            let tr = CGAffineTransform(translationX: -W / 2, y: -H / 2)
                .concatenating(CGAffineTransform(rotationAngle: rotate))
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: W / 2 + dx, y: H / 2 + dy))
            return image.clampedToExtent().transformed(by: tr).cropped(to: rect)
        }
        func screen(_ layer: CIImage?) -> CIImage {
            guard let layer else { return image }
            return layer.cropped(to: rect).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        }
        func gen(_ name: String, _ params: [String: Any]) -> CIImage? { CIFilter(name: name, parameters: params)?.outputImage }
        func rnd(_ n: Double) -> Double { let x = sin(n * 12.9898 + 78.233) * 43758.5453; return x - floor(x) }
        func channel(_ img: CIImage, r: Double, g: Double, b: Double) -> CIImage {
            img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        }
        func rgbSplit(_ px: Double) -> CIImage {
            let red = channel(image, r: 1, g: 0, b: 0).transformed(by: CGAffineTransform(translationX: px, y: 0))
            let green = channel(image, r: 0, g: 1, b: 0)
            let blue = channel(image, r: 0, g: 0, b: 1).transformed(by: CGAffineTransform(translationX: -px, y: 0))
            return red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue]).cropped(to: rect)
        }

        switch e.kind {
        // Motion
        case .zoomPulse:
            let ph = (lt * 2 * sp).truncatingRemainder(dividingBy: 1)
            out = scaled(1 + 0.12 * i * pow(1 - ph, 3))
        case .heartbeat:
            let ph = (lt * sp).truncatingRemainder(dividingBy: 1)
            let p = exp(-pow((ph - 0.1) / 0.05, 2)) + 0.7 * exp(-pow((ph - 0.3) / 0.05, 2))
            out = scaled(1 + 0.08 * i * p)
        case .shake:
            out = scaled(1.05, dx: sin(lt * 47 * sp) * 14 * i * k, dy: cos(lt * 53 * sp) * 10 * i * k)
        case .earthquake:
            out = scaled(1.1, rotate: sin(lt * 31 * sp) * 0.03 * i, dx: sin(lt * 61 * sp) * 30 * i * k, dy: cos(lt * 57 * sp) * 24 * i * k)
        case .slowZoom:
            out = scaled(1 + 0.18 * i * (e.wholeTimeline ? min(1, lt / 8) : u))
        case .spinIn:
            let a = max(0, 1 - lt / 0.6)
            out = scaled(1 + 0.3 * a * i, rotate: 2 * .pi * i * a * a)
        case .bounce:
            out = scaled(1.04, dy: abs(sin(lt * .pi * 2 * sp)) * 36 * i * k)
        case .strobe:
            if (lt * 8 * sp).truncatingRemainder(dividingBy: 1) < 0.5 { out = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.6 * i]) }

        // Light
        case .flash:
            let ph = e.wholeTimeline ? (lt * 0.5 * sp).truncatingRemainder(dividingBy: 1) * 2 : lt
            out = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2.5 * i * exp(-ph * 6)])
        case .lightLeak:
            let x = W * (0.15 + 0.7 * (0.5 + 0.5 * sin(lt * 0.6 * sp)))
            out = screen(gen("CIRadialGradient", ["inputCenter": CIVector(x: x, y: H * 0.72), "inputRadius0": 0, "inputRadius1": W * 0.85,
                                                   "inputColor0": CIColor(red: 1, green: 0.5, blue: 0.18, alpha: 0.6 * i),
                                                   "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)]))
        case .glow:
            out = image.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 10 * k, kCIInputIntensityKey: 0.8 * i])
        case .bloom:
            out = image.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 22 * k, kCIInputIntensityKey: 1.3 * i])
        case .sparkle:
            var acc = image
            for n in 0..<4 {
                let tw = 0.5 + 0.5 * sin(lt * (3 + Double(n)) * sp + Double(n) * 1.7)
                if let star = gen("CIStarShineGenerator", ["inputCenter": CIVector(x: W * rnd(Double(n) + 1), y: H * rnd(Double(n) + 9)),
                                                           "inputColor": CIColor(red: 1, green: 0.95, blue: 0.85, alpha: tw * i),
                                                           "inputRadius": 4 * k, "inputCrossScale": 12, "inputCrossAngle": 0.6,
                                                           "inputCrossOpacity": -2, "inputCrossWidth": 1.6 * k, "inputEpsilon": -2]) {
                    acc = star.cropped(to: rect).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: acc])
                }
            }
            out = acc
        case .sunFlare:
            out = screen(gen("CISunbeamsGenerator", ["inputCenter": CIVector(x: W * 0.82, y: H * 0.88),
                                                     "inputColor": CIColor(red: 1, green: 0.78, blue: 0.45, alpha: 0.8 * i),
                                                     "inputSunRadius": 40 * k, "inputMaxStriationRadius": 2.6,
                                                     "inputStriationStrength": 0.5, "inputStriationContrast": 1.4, "inputTime": lt * 0.2 * sp]))
        case .neonEdges:
            let edges = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6 * i])
                .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: plan.accent.red, y: 0, z: 0, w: 0),
                                                              "inputGVector": CIVector(x: 0, y: plan.accent.green, z: 0, w: 0),
                                                              "inputBVector": CIVector(x: 0, y: 0, z: plan.accent.blue, w: 0)])
            let dim = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.25 * i])
            out = edges.cropped(to: rect).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: dim])
        case .spotlight:
            out = image.applyingFilter("CIVignetteEffect", parameters: [kCIInputCenterKey: CIVector(x: W * (0.5 + 0.25 * sin(lt * 0.7 * sp)), y: H * 0.55),
                                                                        kCIInputRadiusKey: W * 0.55, kCIInputIntensityKey: i, "inputFalloff": 0.6])

        // Colour
        case .noir: out = mix(image.applyingFilter("CIPhotoEffectNoir"), i)
        case .chrome: out = mix(image.applyingFilter("CIPhotoEffectChrome"), i)
        case .faded: out = mix(image.applyingFilter("CIPhotoEffectFade"), i)
        case .instant: out = mix(image.applyingFilter("CIPhotoEffectInstant"), i)
        case .tonal: out = mix(image.applyingFilter("CIPhotoEffectTonal"), i)
        case .sepia: out = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: i])
        case .invert: out = mix(image.applyingFilter("CIColorInvert"), i)
        case .rainbowShift: out = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: lt * 2 * sp * max(0.2, i)])
        case .thermal:
            out = mix(image.applyingFilter("CIFalseColor", parameters: ["inputColor0": CIColor(red: 0.1, green: 0, blue: 0.5), "inputColor1": CIColor(red: 1, green: 0.85, blue: 0.1)]), i)
        case .duotone:
            out = mix(image.applyingFilter("CIFalseColor", parameters: ["inputColor0": CIColor(red: 0.08, green: 0.06, blue: 0.2), "inputColor1": plan.accent]), i)
        case .posterize: out = image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 8 - 5 * i])
        case .warmth:
            out = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + 3000 * i, y: 0)])
        case .cool:
            out = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - 2200 * i, y: 0)])
        case .tealOrange:
            out = mix(LookFilter.apply(.tealOrange, to: image, canvas: plan.canvas), i)

        // Retro
        case .rgbSplit: out = rgbSplit(9 * i * k * (1 + 0.4 * sin(lt * 9 * sp)))
        case .glitch:
            let slot = floor(lt * 9 * sp)
            if rnd(slot) > 0.45 {
                var g = rgbSplit((10 + 30 * rnd(slot + 3)) * i * k)
                for b in 0..<3 {
                    let y = H * rnd(slot + Double(b) * 7), h = H * (0.02 + 0.06 * rnd(slot + Double(b) * 11))
                    let band = image.cropped(to: CGRect(x: 0, y: y, width: W, height: h))
                        .transformed(by: CGAffineTransform(translationX: (rnd(slot + Double(b)) - 0.5) * 120 * i * k, y: 0))
                    g = band.composited(over: g)
                }
                out = g.cropped(to: rect)
            }
        case .grain:
            if let noise = gen("CIRandomGenerator", [:]) {
                let shift = CGAffineTransform(translationX: CGFloat(rnd(floor(lt * 24)) * 500), y: CGFloat(rnd(floor(lt * 24) + 1) * 500))
                let mono = noise.transformed(by: shift).cropped(to: rect)
                    .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                                                                  "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                out = mix(mono.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image]), 0.35 + 0.5 * i)
            }
        case .vhsLines:
            var base = rgbSplit(4 * i * k).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2])
            if let stripes = gen("CIStripesGenerator", ["inputCenter": CIVector(x: 0, y: lt * 40 * sp), "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.28 * i),
                                                         "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0), "inputWidth": 2 * k, "inputSharpness": 0.5]) {
                base = stripes.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: rect).composited(over: base)
            }
            out = base
        case .halftone:
            out = mix(image.applyingFilter("CICMYKHalftone", parameters: [kCIInputCenterKey: c, kCIInputWidthKey: 10 * k, "inputSharpness": 0.7]), i)
        case .letterbox:
            let bar = H * 0.12 * i
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            out = black.cropped(to: CGRect(x: 0, y: 0, width: W, height: bar))
                .composited(over: black.cropped(to: CGRect(x: 0, y: H - bar, width: W, height: bar)))
                .composited(over: image)
        case .vignette:
            out = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 2 * i, kCIInputRadiusKey: 1.6])
        case .comic: out = mix(image.applyingFilter("CIComicEffect"), i)
        case .dots: out = mix(image.applyingFilter("CIDotScreen", parameters: [kCIInputCenterKey: c, kCIInputWidthKey: 7 * k, kCIInputSharpnessKey: 0.7]), i)

        // Distort
        case .mirror:
            let left = image.cropped(to: CGRect(x: 0, y: 0, width: W / 2, height: H))
            out = left.transformed(by: CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(translationX: W, y: 0))).composited(over: image)
        case .mirrorVertical:
            let top = image.cropped(to: CGRect(x: 0, y: H / 2, width: W, height: H / 2))
            out = top.transformed(by: CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: 0, y: H))).composited(over: image)
        case .quad:
            let half = image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            out = [CGPoint(x: 0, y: 0), CGPoint(x: W / 2, y: 0), CGPoint(x: 0, y: H / 2), CGPoint(x: W / 2, y: H / 2)].reduce(image) { acc, p in
                half.transformed(by: CGAffineTransform(translationX: p.x, y: p.y)).composited(over: acc)
            }
        case .kaleidoscope:
            out = mix(image.applyingFilter("CIKaleidoscope", parameters: ["inputCount": 6, kCIInputCenterKey: c, kCIInputAngleKey: lt * 0.3 * sp]), i)
        case .twirl:
            out = image.applyingFilter("CITwirlDistortion", parameters: [kCIInputCenterKey: c, kCIInputRadiusKey: W * 0.5, kCIInputAngleKey: 3 * i * sin(lt * sp)])
        case .bulge:
            out = image.applyingFilter("CIBumpDistortion", parameters: [kCIInputCenterKey: c, kCIInputRadiusKey: W * 0.45, kCIInputScaleKey: 0.6 * i])
        case .pinch:
            out = image.applyingFilter("CIPinchDistortion", parameters: [kCIInputCenterKey: c, kCIInputRadiusKey: W * 0.5, kCIInputScaleKey: 0.6 * i])
        case .pixelate:
            out = image.applyingFilter("CIPixellate", parameters: [kCIInputCenterKey: c, kCIInputScaleKey: (6 + 40 * i) * k])
        case .hexagon:
            out = image.applyingFilter("CIHexagonalPixellate", parameters: [kCIInputCenterKey: c, kCIInputScaleKey: (8 + 30 * i) * k])
        case .crystal:
            out = image.applyingFilter("CICrystallize", parameters: [kCIInputCenterKey: c, kCIInputRadiusKey: (8 + 30 * i) * k])
        case .fisheye:
            out = image.applyingFilter("CIBumpDistortion", parameters: [kCIInputCenterKey: c, kCIInputRadiusKey: W, kCIInputScaleKey: 0.9 * i])

        // Blur
        case .blurIn:
            let r = 30 * i * max(0, 1 - lt / 0.8) * k
            if r > 0.5 { out = image.clampedToExtent().applyingGaussianBlur(sigma: r) }
        case .zoomBlur:
            out = image.applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: c, kCIInputAmountKey: 22 * i * k])
        case .motionBlur:
            out = image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 20 * i * k, kCIInputAngleKey: 0])
        case .dreamy:
            let soft = image.clampedToExtent().applyingGaussianBlur(sigma: 18 * k).cropped(to: rect)
            out = mix(soft.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image]), 0.6 * i)
        case .tiltShift:
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 14 * i * k).cropped(to: rect)
            if let top = gen("CILinearGradient", ["inputPoint0": CIVector(x: 0, y: H), "inputPoint1": CIVector(x: 0, y: H * 0.64),
                                                  "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0)]),
               let bottom = gen("CILinearGradient", ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: H * 0.36),
                                                     "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0)]) {
                let mask = top.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: bottom]).cropped(to: rect)
                out = blurred.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            }
        case .sharpen:
            out = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 2 * i])
        }
        return out.cropped(to: rect)
    }
}
