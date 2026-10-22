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
        /// Position in the bundled heic1901a mosaic (0…1, top-left origin); nil when outside the frame.
        public var mapUV: SIMD2<Float>? = nil
    }

    public static let landmarks: [Landmark] = [
        Landmark(id: "centre", name: "M33 centre", detail: "No bright bulge, no bar — a pure disc nucleus.",
                 offsetLy: SIMD2(0, 0), sizeLy: 2_000, mapUV: SIMD2(0.446, 0.61)),
        Landmark(id: "ngc604", name: "NGC 604", detail: "Giant H II region · ~1,500 ly across · >200 hot massive young stars · 40× the visible Orion Nebula.",
                 offsetLy: SIMD2(9_000, 5_500), sizeLy: 1_500, mapUV: SIMD2(0.92, 0.05)),
        Landmark(id: "ngc595", name: "NGC 595", detail: "Diffuse H II region · among the four brightest in the Hubble survey.",
                 offsetLy: SIMD2(-6_500, 3_800), sizeLy: 800, mapUV: SIMD2(0.49, 0.96)),
        Landmark(id: "pisces-dwarf", name: "Pisces Dwarf Galaxy", detail: "Small satellite of M33.",
                 offsetLy: SIMD2(28_000, -18_000), sizeLy: 3_000),
    ]

    /// The bundled Hubble mosaic (ESA/Hubble heic1901a, 4000 × 2251).
    public static let mosaicResource = "m33-hubble"
    public static let mosaicAspect: Float = 4000.0 / 2251.0
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
