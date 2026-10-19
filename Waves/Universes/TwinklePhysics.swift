// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes — why stars twinkle: real physics only. Spec §5.
// No decorative sin() flicker: variability, Kolmogorov scintillation, shot noise.

import Foundation

public enum TwinklePhysics {

    // MARK: §5.1 Intrinsic variability — flux multiplier & temperature at phase

    /// Returns (fluxMultiplier, temperatureK) for a star at `timeDays` (days, arbitrary epoch).
    public static func intrinsicState(of star: StarBody, atDays t: Double) -> (flux: Double, temperatureK: Double) {
        switch star.variability {
        case .steady:
            return (1, star.temperatureK)
        case .cepheid(let period, let amp):
            // Radial pulsation: brightness and temperature vary together (bluer when brighter).
            let phase = 2 * Double.pi * (t.truncatingRemainder(dividingBy: period) / period)
            let mag = -amp * 0.5 * cos(phase) // magnitude offset (negative = brighter)
            let flux = pow(10, -0.4 * mag)
            let temp = star.temperatureK * (1 + 0.08 * cos(phase))
            return (flux, temp)
        case .rrLyrae(let period, let amp):
            let phase = (t.truncatingRemainder(dividingBy: period) / period)
            // Sawtooth-like fast rise, slow fall.
            let shape = phase < 0.15 ? phase / 0.15 : 1 - (phase - 0.15) / 0.85
            return (pow(10, 0.4 * amp * shape), star.temperatureK * (1 + 0.05 * shape))
        case .eclipsing(let period, let depth):
            let phase = t.truncatingRemainder(dividingBy: period) / period
            let inEclipse = phase < 0.05 || phase > 0.95
            return (inEclipse ? pow(10, -0.4 * depth) : 1, star.temperatureK)
        case .mira(let period, let amp):
            let phase = 2 * Double.pi * (t.truncatingRemainder(dividingBy: period) / period)
            return (pow(10, 0.4 * amp * (0.5 - 0.5 * cos(phase))), star.temperatureK * (1 - 0.1 * cos(phase)))
        case .flare:
            // Deterministic pseudo-flare from a hashed day bucket (stable per render, stochastic in time).
            let bucket = Int(t * 24)
            var h = UInt64(bitPattern: Int64(bucket &* 2654435761))
            h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
            let u = Double(h % 10_000) / 10_000
            return (u > 0.995 ? 3.0 : 1.0, star.temperatureK)
        }
    }

    // MARK: §5.2 Atmospheric scintillation — Kolmogorov turbulence (Earth modes only)

    /// Fried parameter r0 in metres (0.10 m at 500 nm is typical good seeing).
    public struct Atmosphere: Sendable {
        public var r0Metres: Double = 0.10
        public var windMetresPerSecond: Double = 10
        public var enabled: Bool = false // off in space; on for tonight/AR-sky
        public static let space = Atmosphere(enabled: false)
        public static let earthDefault = Atmosphere(enabled: true)
    }

    /// Scintillation index σI² ∝ λ^-7/6 · (sec z)^11/6 · r0^-5/3 (normalised at 500 nm, zenith).
    public static func scintillationIndex(wavelengthNm: Double, zenithAngleRad: Double, atmosphere: Atmosphere) -> Double {
        guard atmosphere.enabled else { return 0 }
        let secZ = 1 / max(cos(zenithAngleRad), 0.1)
        let lambdaFactor = pow(wavelengthNm / 500, -7.0 / 6.0)
        let r0Factor = pow(atmosphere.r0Metres / 0.10, -5.0 / 3.0)
        return 0.12 * lambdaFactor * pow(secZ, 11.0 / 6.0) * r0Factor
    }

    /// Instantaneous intensity multiplier for one star: frozen-flow phase screen proxy.
    /// Planets pass angularDiameterArcsec large → averaged out → steady (as observed).
    public static func scintillationMultiplier(
        star: StarBody, atSeconds t: Double, wavelengthNm: Double,
        zenithAngleRad: Double, angularDiameterArcsec: Double, atmosphere: Atmosphere
    ) -> Double {
        guard atmosphere.enabled else { return 1 }
        let sigma2 = scintillationIndex(wavelengthNm: wavelengthNm, zenithAngleRad: zenithAngleRad, atmosphere: atmosphere)
        // Extended sources (planets ~10–60″) average over many cells: suppress by disc size.
        let suppression = 1 / (1 + angularDiameterArcsec / 2.0)
        let s = sigma2 * suppression
        // Two-cell frozen flow: deterministic per star (seeded by id), evolving with wind/t.
        let seed = Double(abs(star.id.hashValue % 628)) / 100
        let phase = 2 * Double.pi * (t * atmosphere.windMetresPerSecond / 0.3 + seed)
        let noise = sin(phase) * 0.6 + sin(phase * 2.7 + seed) * 0.4
        return max(1 + noise * s.squareRoot(), 0.05)
    }

    // MARK: §5.3 Photon shot noise (Poisson counting at the faint limit)

    /// Expected detected photons; relative RMS = 1/√N. Faint Hubble stars flicker from counting alone.
    public static func shotNoiseRelativeRMS(expectedPhotons: Double) -> Double {
        expectedPhotons > 0 ? 1 / expectedPhotons.squareRoot() : 0
    }

    /// Which twinkle is dominant — shown in the UI so the effect is always explained.
    public static func dominantTwinkleLabel(for star: StarBody, atmosphere: Atmosphere) -> String {
        if star.variability != .steady { return "\(star.variability.className) · the star itself" }
        if atmosphere.enabled { return "scintillation · Earth's air" }
        if star.apparentMagnitude > 18 { return "photon counting · shot noise" }
        return "steady in space"
    }
}
