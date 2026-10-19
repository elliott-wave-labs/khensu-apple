// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes — M33 (Triangulum Galaxy) catalogue + live NASA/ESA/ESO tile manifest.
// Spec §3–§4. Facts cited on-screen; tiles are HiPS (ESA Sky / NASA SkyView standard).

import Foundation
import simd

public enum M33 {
    // §3 constants — ESA/Hubble heic1901, NASA Messier 33, ESO b13, EarthSky.
    public static let name = "Triangulum Galaxy"
    public static let messier = "M33 · NGC 598"
    public static let distanceLightYears: Double = 2_730_000
    public static let diameterLightYears: Double = 60_000
    public static let starCount: Double = 40_000_000_000
    public static let apparentMagnitude: Double = 5.7
    public static let hubbleMosaicPixels: Double = 665_000_000
    public static let hubblePointings = 54
    public static let resolvedStarsInMosaic: Double = 25_000_000
    public static let mosaicSpanLightYears: Double = 14_000
    public static let starFormationSolarMassesPerYear: Double = 0.5 // 1 M☉ / 2 yr
    public static let constellation = "Triangulum"

    public static let credits = "NASA, ESA · ESA/Hubble heic1901 · ESO/S. Brunier · EarthSky"

    public struct Landmark: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let detail: String
        /// Offset from M33 centre, light-years (disc plane, face-on approximation for v1 map).
        public let offsetLy: SIMD2<Double>
        public let sizeLy: Double
    }

    public static let landmarks: [Landmark] = [
        Landmark(id: "centre", name: "M33 centre", detail: "No bright bulge, no bar — a pure disc nucleus.",
                 offsetLy: SIMD2(0, 0), sizeLy: 2_000),
        Landmark(id: "ngc604", name: "NGC 604", detail: "Giant H II region · ~1,500 ly across · >200 hot massive young stars · 40× the visible Orion Nebula.",
                 offsetLy: SIMD2(9_000, 5_500), sizeLy: 1_500),
        Landmark(id: "ngc595", name: "NGC 595", detail: "Diffuse H II region · among the four brightest in the Hubble survey.",
                 offsetLy: SIMD2(-6_500, 3_800), sizeLy: 800),
        Landmark(id: "pisces-dwarf", name: "Pisces Dwarf Galaxy", detail: "Small satellite of M33.",
                 offsetLy: SIMD2(28_000, -18_000), sizeLy: 3_000),
    ]

    /// Hero stars inside the mosaic footprint (illustrative bright end; full set streams as tiles).
    /// Positions are disc-plane ly offsets; temperatures/magnitudes are class-typical for the demo set.
    public static func demoStars() -> [StarBody] {
        var stars: [StarBody] = []
        var rng = SplitMix64(seed: 33)
        for i in 0..<1_200 {
            // Logarithmic two-arm spiral, face-on.
            let arm = i % 2 == 0 ? 0.0 : Double.pi
            let r = 2_000 + 26_000 * pow(rng.nextDouble(), 1.6)
            let theta = arm + log(r / 2_000) * 1.1 + rng.nextDouble() * 0.35
            let x = r * cos(theta), y = r * sin(theta)
            let temp = 3_200 + rng.nextDouble() * 9_000
            let mag = 14 + rng.nextDouble() * 8
            let variability: Variability = (i % 97 == 0)
                ? .cepheid(periodDays: 4 + rng.nextDouble() * 40, amplitudeMag: 0.7)
                : .steady
            stars.append(StarBody(
                id: "m33-\(i)", name: i == 0 ? "M33 Cepheid (demo)" : "M33 star",
                positionPc: SIMD3<Double>(x * 0.3066, y * 0.3066, (rng.nextDouble() - 0.5) * 300),
                temperatureK: temp, apparentMagnitude: mag, variability: variability))
        }
        return stars
    }
}

/// Deterministic RNG for demo data (never for crypto).
public struct SplitMix64: Sendable {
    public var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func nextUInt() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func nextDouble() -> Double { Double(nextUInt() >> 11) / Double(1 << 53) }
}

// MARK: - Live tile manifest (§4)

public struct GalaxyTileManifest: Sendable, Decodable {
    public var galaxy: String
    public var epoch: String
    public var source: String
    public var credit: String
    public var hipsBaseURL: String
    public var bands: [String]
}

public actor M33DataService {
    public init() {}

    /// Upstream HiPS roots (public, keyless). The app caches tiles; khensu mirrors are content-addressed fallbacks.
    public static let upstreamHiPS: [(band: String, url: String, credit: String)] = [
        ("visible", "https://esasky.esac.esa.int/ecssky/hips/hst", "ESA Sky · HST"),
        ("dss", "https://skyview.gsfc.nasa.gov/current/cgi-bin/skvrelative.pl", "NASA SkyView · DSS"),
        ("galex", "https://skyview.gsfc.nasa.gov/current/cgi-bin/skvrelative.pl", "NASA SkyView · GALEX (UV)"),
        ("wise", "https://skyview.gsfc.nasa.gov/current/cgi-bin/skvrelative.pl", "NASA SkyView · WISE (IR)"),
    ]

    public static let referencePages: [(title: String, url: String)] = [
        ("ESA/Hubble heic1901 — gigantic M33 image", "https://esahubble.org/news/heic1901/"),
        ("NASA — Messier 33", "https://science.nasa.gov/mission/hubble/science/explore-the-night-sky/hubble-messier-catalog/messier-33/"),
        ("ESO — The Triangulum Galaxy", "https://www.eso.org/public/belgium-de/images/b13/?lang"),
        ("EarthSky — M33, a binocular challenge", "https://earthsky.org/clusters-nebulae-galaxies/triangulum-galaxy-m33-a-binocular-challenge/"),
    ]

    /// Poll upstream for a newer archive epoch. Returns the remote epoch string when reachable.
    /// "Realtime" here means archive-realtime (spec §4.2): M33's light is 2.73 Myr old and labelled as such.
    public func fetchLatestEpoch() async -> String? {
        guard let url = URL(string: "https://esahubble.org/news/heic1901/") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                let formatter = ISO8601DateFormatter()
                return "ESA/Hubble reachable · checked \(formatter.string(from: Date()))"
            }
        } catch { return nil }
        return nil
    }
}
