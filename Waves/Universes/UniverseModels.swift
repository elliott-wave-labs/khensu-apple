// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes (nu.u) — universe model: scales, cosmic time, 19-channel spectra.
// Spec: khensu-specs/design/nu-universes.md §§2, 6. Nothing processed on servers.

import Foundation
import simd

// MARK: - Scale layers (§2.1)

public enum UniverseScale: Int, CaseIterable, Sendable {
    case room = 0, sky, solarSystem, milkyWay, localGroup, m33DeepMap, universe

    public var title: String {
        switch self {
        case .room: return "Room · AR"
        case .sky: return "Tonight's sky"
        case .solarSystem: return "Solar System"
        case .milkyWay: return "Milky Way"
        case .localGroup: return "Local Group"
        case .m33DeepMap: return "M33 Deep Map"
        case .universe: return "Universe"
        }
    }
    /// Characteristic extent in parsecs (room is metres, flagged separately).
    public var extentParsecs: Double {
        switch self {
        case .room: return 0
        case .sky: return 1
        case .solarSystem: return 0.001
        case .milkyWay: return 60_000 * 0.3066
        case .localGroup: return 3_000_000 * 0.3066
        case .m33DeepMap: return 60_000 * 0.3066
        case .universe: return 14_000_000_000
        }
    }
}

// MARK: - Cosmic time (§2.2) — FLRW, Planck-class parameters (versioned)

public struct Cosmology: Sendable {
    public var h0KmSPerMpc: Double = 67.4
    public var omegaM: Double = 0.315
    public var omegaLambda: Double = 0.685
    public var omegaR: Double = 9.2e-5
    public var t0Gyr: Double = 13.8
    public var cmbT0Kelvin: Double = 2.725
    public static let v1 = Cosmology()

    public var omegaK: Double { 1 - omegaM - omegaLambda - omegaR }

    /// E(a) = H(a)/H0.
    public func eFactor(scaleFactor a: Double) -> Double {
        let a2 = a * a
        return (omegaR / (a2 * a2) + omegaM / (a2 * a) + omegaK / a2 + omegaLambda).squareRoot()
    }

    /// Lookback-integrated cosmic time (Gyr) for scale factor `a`, RK4 on a cached grid.
    public func timeGyr(scaleFactor a: Double) -> Double {
        // Analytic-friendly numeric integral: t = ∫0^a da' / (a' H(a')).
        // H0 in Gyr^-1: H0 [km/s/Mpc] * 1.022e-3 = per-Gyr.
        let h0PerGyr = h0KmSPerMpc * 1.022e-3
        guard a > 0 else { return 0 }
        var sum = 0.0
        // Trapezoid on log-spaced grid (stable from a→0).
        let steps = 1024
        let logMin = log(1e-6), logMax = log(max(a, 1e-6))
        var prevA = exp(logMin)
        var prevF = integrand(prevA, h0PerGyr: h0PerGyr)
        for i in 1...steps {
            let ai = exp(logMin + (logMax - logMin) * Double(i) / Double(steps))
            let fi = integrand(ai, h0PerGyr: h0PerGyr)
            sum += 0.5 * (prevF + fi) * (ai - prevA)
            prevA = ai; prevF = fi
        }
        return sum
    }
    private func integrand(_ a: Double, h0PerGyr: Double) -> Double {
        1.0 / max(a * h0PerGyr * eFactor(scaleFactor: a), 1e-12)
    }

    public func cmbTemperatureKelvin(redshift z: Double) -> Double { cmbT0Kelvin * (1 + z) }
}

/// A moment on the nu.u timeline. Negative = Gyr before today handled via `gyrAfterBigBang`.
public struct CosmicTime: Sendable, Equatable {
    /// Gyr after the Big Bang. Today = 13.8. Future prediction up to 23.8 (+10 Gyr).
    public var gyrAfterBigBang: Double
    public var isPrediction: Bool { gyrAfterBigBang > Cosmology.v1.t0Gyr + 1e-9 }
    public static let bigBang = CosmicTime(gyrAfterBigBang: 0)
    public static let recombination = CosmicTime(gyrAfterBigBang: 0.00038) // 380 kyr
    public static let today = CosmicTime(gyrAfterBigBang: 13.8)
    public static let milkomeda = CosmicTime(gyrAfterBigBang: 17.8) // ~+4 Gyr

    public var label: String {
        if gyrAfterBigBang < 0.001 { return "\(Int((gyrAfterBigBang * 1e6).rounded())) kyr after the Big Bang" }
        if isPrediction { return "+\(String(format: "%.1f", gyrAfterBigBang - 13.8)) Gyr · predicted" }
        if gyrAfterBigBang >= 13.79 { return "Today" }
        return "\(String(format: "%.2f", gyrAfterBigBang)) Gyr after the Big Bang"
    }
}

// MARK: - Wavelength bands (§6.1)

public enum SpectrumBand: String, CaseIterable, Sendable, Identifiable {
    case gamma, xray, ultraviolet, visible, infrared, microwave, radio, mantis, audible
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .gamma: return "Gamma ray"
        case .xray: return "X-ray"
        case .ultraviolet: return "UV"
        case .visible: return "Visible"
        case .infrared: return "Infrared"
        case .microwave: return "Microwave"
        case .radio: return "Radio"
        case .mantis: return "Mantis · 19ch"
        case .audible: return "Sound"
        }
    }
    /// Log10 wavelength range in metres (gamma shortest → radio longest).
    public var logWavelengthMetres: ClosedRange<Double> {
        switch self {
        case .gamma: return -14 ... -11
        case .xray: return -11 ... -8
        case .ultraviolet: return -8 ... -6.4
        case .visible: return -6.4 ... -6.15
        case .infrared: return -6.15 ... -3
        case .microwave: return -3 ... -0.5
        case .radio: return -0.5 ... 4
        case .mantis: return -7.5 ... -6.15 // UV→red, mantis chromatic range
        case .audible: return 1 ... 4 // sonified: not a wavelength, a mapping
        }
    }
    public var isObserverMode: Bool { self == .mantis || self == .audible }
}

// MARK: - 19-channel spectral cube (§§2.3, 6.3)

/// 19 channels: 12 spectral (UV→red), 4 linear-pol, 1 circular-pol, intensity, midband-scan.
/// Mantis biology: 16 photoreceptor types (12 chromatic). The renderer carries 19 so the
/// mantis observer, polarisation and intensity all read the same cube. See spec §6.3.
public struct SpectralCube: Sendable, Equatable {
    public static let channelCount = 19
    /// Peak wavelengths (nm) for the 12 chromatic channels; mantis-class peaks UV→red.
    public static let chromaticPeaksNm: [Double] = [330, 365, 400, 440, 470, 500, 530, 560, 590, 620, 660, 700]
    public var channels: [Float] // count == 19, linear flux, arbitrary units (normalised per object)
    public init(channels: [Float]) {
        precondition(channels.count == Self.channelCount)
        self.channels = channels
    }
    /// Blackbody chromatic channels (Planck, per-channel Gaussian response at each peak).
    public static func blackbody(temperatureK: Double, flux: Float = 1) -> SpectralCube {
        var ch = [Float](repeating: 0, count: channelCount)
        for (i, nm) in chromaticPeaksNm.enumerated() {
            let lambdaM = nm * 1e-9
            let x = 1.4388e7 / (nm * max(temperatureK, 1)) // hc/k in nm·K
            let planck = 1.0 / (pow(lambdaM, 5) * (exp(x) - 1) + 1e-30)
            ch[i] = Float(planck)
        }
        let maxV = max(ch.max() ?? 1, 1e-30)
        for i in 0..<12 { ch[i] = ch[i] / maxV * flux }
        ch[16] = flux // intensity = peak-normalised total proxy
        // Polarisation channels default 0 (unpolarised blackbody); callers with scattering set them.
        return SpectralCube(channels: ch)
    }
}

// MARK: - Observer (§6)

public enum Observer: Sendable, Equatable {
    case human
    case band(SpectrumBand) // instrument band, false colour
    case mantisStrip        // 19-channel contact sheet
    case mantisOpponent     // discriminability-preserving projection
    case polarisation       // degree/angle of polarisation
    case audible            // sonify through nu.waves

    public static func from(band: SpectrumBand) -> Observer {
        switch band {
        case .visible: return .human
        case .mantis: return .mantisOpponent
        case .audible: return .audible
        default: return .band(band)
        }
    }
}

// MARK: - Catalogue bodies

public struct StarBody: Sendable, Identifiable {
    public let id: String
    public var name: String
    /// Galactocentric Cartesian, parsecs.
    public var positionPc: SIMD3<Double>
    public var temperatureK: Double
    public var apparentMagnitude: Double
    public var variability: Variability
    public var cube: SpectralCube

    public init(id: String, name: String, positionPc: SIMD3<Double>, temperatureK: Double,
                apparentMagnitude: Double, variability: Variability) {
        self.id = id; self.name = name; self.positionPc = positionPc
        self.temperatureK = temperatureK; self.apparentMagnitude = apparentMagnitude
        self.variability = variability
        self.cube = .blackbody(temperatureK: temperatureK)
    }
}

public enum Variability: Sendable, Equatable {
    case steady
    case cepheid(periodDays: Double, amplitudeMag: Double)
    case rrLyrae(periodDays: Double, amplitudeMag: Double)
    case eclipsing(periodDays: Double, depthMag: Double)
    case mira(periodDays: Double, amplitudeMag: Double)
    case flare(ratePerDay: Double)

    public var className: String {
        switch self {
        case .steady: return "steady"
        case .cepheid: return "Cepheid"
        case .rrLyrae: return "RR Lyrae"
        case .eclipsing: return "eclipsing"
        case .mira: return "Mira"
        case .flare: return "flare star"
        }
    }
}
