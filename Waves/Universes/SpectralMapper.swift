// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes — project the 19-channel cube for each observer. Spec §6.
// Human = true colour. Every other observer is labelled false colour / mapped.

import Foundation
import simd

public enum SpectralMapper {

    /// Human trichromatic projection: weighted sum of chromatic channels into RGB.
    /// Weights approximate cone fundamentals sampled at the channel peaks — v1, pinned in UniversesView tests.
    public static func humanRGB(_ cube: SpectralCube) -> SIMD3<Float> {
        // (R,G,B) response per chromatic channel peak [330…700 nm].
        let w: [(Float, Float, Float)] = [
            (0.05, 0, 0.10), (0.08, 0, 0.18), (0.10, 0.02, 0.35), (0.05, 0.10, 0.55),
            (0, 0.25, 0.45), (0, 0.55, 0.20), (0.05, 0.80, 0.05), (0.35, 0.85, 0),
            (0.70, 0.70, 0), (0.95, 0.40, 0), (1.0, 0.12, 0), (0.90, 0.02, 0),
        ]
        var rgb = SIMD3<Float>(0, 0, 0)
        for i in 0..<12 {
            let f = cube.channels[i]
            rgb += SIMD3<Float>(w[i].0 * f, w[i].1 * f, w[i].2 * f)
        }
        return rgb
    }

    /// Band false colour: map a band's representative channels to a hue-ramped RGB.
    public static func bandRGB(_ cube: SpectralCube, band: SpectrumBand) -> SIMD3<Float> {
        let v = cube.channels[16] // intensity
        switch band {
        case .gamma: return SIMD3<Float>(0.8, 0.4, 1.0) * v
        case .xray: return SIMD3<Float>(0.4, 0.7, 1.0) * v
        case .ultraviolet: return SIMD3<Float>(0.55, 0.3, 0.95) * v
        case .visible, .mantis: return humanRGB(cube)
        case .infrared: return SIMD3<Float>(1.0, 0.45, 0.15) * v
        case .microwave: return SIMD3<Float>(1.0, 0.7, 0.3) * v
        case .radio: return SIMD3<Float>(0.2, 0.9, 0.6) * v
        case .audible: return humanRGB(cube) // visual stays human; audio carries the band
        }
    }

    /// Mantis opponent projection (§6.3): keeps *discriminability* — spectra a human calls
    /// identical separate here. Fixed published-style opponent matrix, no learned weights.
    public static func mantisOpponentRGB(_ cube: SpectralCube) -> SIMD3<Float> {
        // Opponents: (UV−B), (G−R), (Y−polarisation-corrected intensity).
        let c = cube.channels
        let uvMinusBlue = c[0] + c[1] - c[3]
        let greenMinusRed = c[6] - c[10]
        let yellow = (c[7] + c[8]) * 0.5 - c[13] * 0.3
        return SIMD3<Float>(
            max(greenMinusRed * 0.5 + 0.5, 0) * c[16],
            max(yellow, 0),
            max(uvMinusBlue * 0.5 + 0.3, 0) * c[16]
        )
    }

    /// Polarisation view: degree → brightness, angle → hue (as RGB proxy).
    public static func polarisationRGB(_ cube: SpectralCube) -> SIMD3<Float> {
        let q = Double(cube.channels[12]), u = Double(cube.channels[13])
        let degree = min((q * q + u * u).squareRoot(), 1)
        let angle = atan2(u, q) // -π…π
        let hue = Float((angle + Double.pi) / (2 * Double.pi))
        // Hue → RGB (simple HSV wheel, value = degree × intensity).
        let v = Float(degree) * cube.channels[16]
        let x = hue * 6
        let i = Int(x) % 6
        let f = x - Float(Int(x))
        let base: SIMD3<Float>
        switch i {
        case 0: base = SIMD3(1, f, 0)
        case 1: base = SIMD3(1 - f, 1, 0)
        case 2: base = SIMD3(0, 1, f)
        case 3: base = SIMD3(0, 1 - f, 1)
        case 4: base = SIMD3(f, 0, 1)
        default: base = SIMD3(1, 0, 1 - f)
        }
        return base * v
    }

    public static func rgb(_ cube: SpectralCube, observer: Observer) -> SIMD3<Float> {
        switch observer {
        case .human: return humanRGB(cube)
        case .band(let b): return bandRGB(cube, band: b)
        case .mantisStrip, .mantisOpponent: return mantisOpponentRGB(cube)
        case .polarisation: return polarisationRGB(cube)
        case .audible: return humanRGB(cube)
        }
    }

    // MARK: Sonification (§6.4) — spectrum → nu.waves parameters

    public struct Sonification: Sendable, Equatable {
        public var fundamentalHz: Double
        public var loudness: Double // 0…1
        public var brightness: Double // spectral centroid 0…1 (→ timbre / filter)
        public var azimuthDegrees: Double // polarisation angle → spacetime bubble position
    }

    /// Log-transpose the cube's chromatic centroid into 20 Hz–20 kHz.
    public static func sonify(_ cube: SpectralCube, band: SpectrumBand) -> Sonification {
        var weighted = 0.0, total = 0.0
        for (i, nm) in SpectralCube.chromaticPeaksNm.enumerated() {
            let f = Double(cube.channels[i])
            weighted += log10(nm) * f; total += f
        }
        let centroid = total > 0 ? weighted / total : log10(550)
        // 330 nm → C4-ish low, 700 nm → high: log map across ~5 octaves from 110 Hz.
        let norm = (centroid - log10(330)) / (log10(700) - log10(330))
        let hz = 110 * pow(2, norm * 5)
        let q = Double(cube.channels[12]), u = Double(cube.channels[13])
        return Sonification(
            fundamentalHz: min(max(hz, 20), 20_000),
            loudness: Double(min(cube.channels[16], 1)),
            brightness: norm,
            azimuthDegrees: atan2(u, q) * 180 / Double.pi
        )
    }
}
