// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes flight catalogue: the same map as khensu.nu/universes. Units are parsecs,
// equatorial J2000, Sun at the origin (+z toward the north celestial pole). Data files are
// built by khensu-specs design/nu-universes/catalog.py: HYG v4.1 stars, the Updated Nearby
// Galaxy Catalog (measured distances) and the 2MASS Redshift Survey.

import Foundation
import simd

enum Flight {
    static let au = 1 / 206_264.806
    static let lightYear = 0.306_601
    static let obliquity = 23.439_28 * .pi / 180

    /// One point source: centre, absolute magnitude, physical diameter (pc), gain, twinkle seed, colour.
    struct Point {
        var position: SIMD3<Float>
        var absMag: Float
        var diameter: Float
        var gain: Float = 1
        var seed: Float = 0
        var tint: SIMD3<Float>
    }

    /// A sprite layer with its own limiting magnitude and zoom exposure.
    struct Layer {
        var name: String
        var points: [Point]
        var limit: Float
        var exposure: Float
        var gainInside: Float? = nil
    }

    struct Place: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var position: SIMD3<Double>
        var view: Double
        var kind: String
        var note: String
        var showWithin: Double
        var minView: Double = 0
        /// Unit vector from the place toward the camera for its best view; nil keeps the current heading.
        var facing: SIMD3<Double>? = nil
        /// Extent (pc) for entering and leaving it on a route; nil for points.
        var radius: Double? = nil
    }

    /// Mostly face-on to a disc, tipped 35° toward the Sun so the view keeps our side of it.
    static func facing(normal: SIMD3<Double>, at pos: SIMD3<Double>) -> SIMD3<Double> {
        let home = simd_length(pos) > 0 ? -simd_normalize(pos) : SIMD3(0, 0, 1)
        let n = simd_dot(normal, home) < 0 ? -normal : normal
        return simd_normalize(n * cos(35 * Double.pi / 180) + home * sin(35 * Double.pi / 180))
    }

    struct Orbit { var name: String; var points: [SIMD3<Float>]; var tint: SIMD3<Float> }

    struct Catalog {
        var layers: [Layer] = []
        var places: [Place] = []
        var orbits: [Orbit] = []
        var m33: SIMD3<Double>?
    }

    // MARK: Planets — NASA JPL "Approximate Positions of the Planets", table 1 (1800–2050)

    struct Elements { var name: String; var el: [Double]; var rate: [Double]; var tint: SIMD3<Float> }
    static let planets: [Elements] = [
        .init(name: "Mercury", el: [0.38709927, 0.20563593, 7.00497902, 252.2503235, 77.45779628, 48.33076593], rate: [0.00000037, 0.00001906, -0.00594749, 149472.67411175, 0.16047689, -0.12534081], tint: [0.6, 0.6, 0.6]),
        .init(name: "Venus", el: [0.72333566, 0.00677672, 3.39467605, 181.9790995, 131.60246718, 76.67984255], rate: [0.0000039, -0.00004107, -0.0007889, 58517.81538729, 0.00268329, -0.27769418], tint: [0.91, 0.83, 0.63]),
        .init(name: "Earth", el: [1.00000261, 0.01671123, -0.00001531, 100.46457166, 102.93768193, 0], rate: [0.00000562, -0.00004392, -0.01294668, 35999.37244981, 0.32327364, 0], tint: [0.44, 0.66, 1]),
        .init(name: "Mars", el: [1.52371034, 0.0933941, 1.84969142, -4.55343205, -23.94362959, 49.55953891], rate: [0.00001847, 0.00007882, -0.00813131, 19140.30268499, 0.44441088, -0.29257343], tint: [0.85, 0.45, 0.29]),
        .init(name: "Jupiter", el: [5.202887, 0.04838624, 1.30439695, 34.39644051, 14.72847983, 100.47390909], rate: [-0.00011607, -0.00013253, -0.00183714, 3034.74612775, 0.21252668, 0.20469106], tint: [0.85, 0.7, 0.54]),
        .init(name: "Saturn", el: [9.53667594, 0.05386179, 2.48599187, 49.95424423, 92.59887831, 113.66242448], rate: [-0.0012506, -0.00050991, 0.00193609, 1222.49362201, -0.41897216, -0.28867794], tint: [0.9, 0.83, 0.61]),
        .init(name: "Uranus", el: [19.18916464, 0.04725744, 0.77263783, 313.23810451, 170.9542763, 74.01692503], rate: [-0.00196176, -0.00004397, -0.00242939, 428.48202785, 0.40805281, 0.04240589], tint: [0.62, 0.88, 0.9]),
        .init(name: "Neptune", el: [30.06992276, 0.00859048, 1.77004347, -55.12002969, 44.96476227, 131.78422574], rate: [0.00026291, 0.00005105, 0.00035372, 218.45945325, -0.32241464, -0.00508664], tint: [0.42, 0.55, 1]),
    ]

    /// Heliocentric equatorial position (pc) at Julian centuries `t` past J2000; `meanAnomaly` overrides for orbit drawing.
    static func position(of p: Elements, t: Double, meanAnomaly: Double? = nil) -> SIMD3<Double> {
        let v = zip(p.el, p.rate).map { $0 + $1 * t }
        let (a, e, inc, l, wbar, node) = (v[0], v[1], v[2] * .pi / 180, v[3], v[4], v[5] * .pi / 180)
        let w = wbar * .pi / 180 - node
        var m = meanAnomaly ?? ((((l - wbar).truncatingRemainder(dividingBy: 360)) + 540).truncatingRemainder(dividingBy: 360) - 180)
        m *= .pi / 180
        var ecc = m + e * sin(m)
        for _ in 0..<8 { ecc -= (ecc - e * sin(ecc) - m) / (1 - e * cos(ecc)) }
        let xp = a * (cos(ecc) - e), yp = a * sqrt(1 - e * e) * sin(ecc)
        let x = (cos(w) * cos(node) - sin(w) * sin(node) * cos(inc)) * xp + (-sin(w) * cos(node) - cos(w) * sin(node) * cos(inc)) * yp
        let y = (cos(w) * sin(node) + sin(w) * cos(node) * cos(inc)) * xp + (-sin(w) * sin(node) + cos(w) * cos(node) * cos(inc)) * yp
        let z = sin(w) * sin(inc) * xp + cos(w) * sin(inc) * yp
        let ce = cos(obliquity), se = sin(obliquity)
        return SIMD3(x, y * ce - z * se, y * se + z * ce) * au
    }

    // MARK: Frames

    /// IAU galactic axes expressed in equatorial J2000 (columns).
    static let galactic = simd_double3x3(rows: [
        SIMD3(-0.0548755604, 0.4941094279, -0.867666149),
        SIMD3(-0.8734370902, -0.44482963, -0.1980763734),
        SIMD3(-0.4838350155, 0.7469822445, 0.4559837762),
    ])
    static let sunR = 8178.0 // GRAVITY Collaboration 2019
    static let sunZ = 20.8
    static func galactocentric(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> {
        galactic * SIMD3(x + sunR, y, z - sunZ)
    }

    /// Disc axes for a galaxy at `pos`: major axis at position angle `pa` (north through east), tilted by `inc`.
    static func discBasis(_ pos: SIMD3<Double>, pa paDeg: Double, inc incDeg: Double) -> (major: SIMD3<Double>, minor: SIMD3<Double>, normal: SIMD3<Double>) {
        let n = simd_normalize(pos)
        let east = simd_normalize(simd_cross(SIMD3(0, 0, 1), n))
        let north = simd_normalize(simd_cross(n, east))
        let pa = paDeg * .pi / 180, inc = incDeg * .pi / 180
        let major = north * cos(pa) + east * sin(pa)
        let minorSky = -north * sin(pa) + east * cos(pa)
        let minor = simd_normalize(minorSky * cos(inc) + n * sin(inc))
        return (major, minor, simd_normalize(simd_cross(major, minor)))
    }

    static func bvToRGB(_ bv: Double) -> SIMD3<Float> {
        let t = 4600 * (1 / (0.92 * bv + 1.7) + 1 / (0.92 * bv + 0.62)), k = t / 100
        let r = k <= 66 ? 1 : min(1, 1.292936 * pow(k - 60, -0.1332047592))
        let g = k <= 66 ? min(1, max(0, 0.390081579 * log(k) - 0.631841444)) : min(1, 1.129890861 * pow(k - 60, -0.0755148492))
        let b = k >= 66 ? 1 : k <= 19 ? 0 : min(1, max(0, 0.543206789 * log(k - 10) - 1.196254089))
        return SIMD3(Float(r), Float(g), Float(b))
    }

    static func distanceText(_ pc: Double) -> String {
        let ly = pc / lightYear, a = pc / au
        func f(_ v: Double, _ d: Int) -> String { v.formatted(.number.precision(.fractionLength(d))) }
        if a < 1000 { return "\(a < 10 ? f(a, 2) : f(a, 0)) AU" }
        if ly < 1000 { return "\(ly < 10 ? f(ly, 2) : f(ly, 0)) light-years" }
        if ly < 1e6 { return "\(f(ly / 1e3, ly < 1e4 ? 2 : 1)) thousand light-years" }
        if ly < 1e9 { return "\(f(ly / 1e6, ly < 1e7 ? 2 : 1)) million light-years" }
        return "\(f(ly / 1e9, 2)) billion light-years"
    }

    static let friendly: [String: (String, String)] = [
        "MESSIER031": ("Andromeda Galaxy · M31", "The nearest large spiral. Heading for the Milky Way."),
        "MESSIER033": ("Triangulum Galaxy · M33", "Third-largest in the Local Group. Hubble mosaic heic1901."),
        "LMC": ("Large Magellanic Cloud", "Satellite of the Milky Way."),
        "SMC": ("Small Magellanic Cloud", "Satellite of the Milky Way."),
        "MESSIER032": ("M32", "Compact satellite of Andromeda."),
        "NGC0205": ("M110", "Satellite of Andromeda."),
        "MESSIER081": ("Bode's Galaxy · M81", "Grand-design spiral in Ursa Major."),
        "MESSIER082": ("Cigar Galaxy · M82", "Starburst galaxy beside M81."),
        "MESSIER101": ("Pinwheel Galaxy · M101", "Face-on spiral."),
        "NGC5194": ("Whirlpool Galaxy · M51", "Spiral interacting with NGC 5195."),
        "NGC4594": ("Sombrero Galaxy · M104", "Edge-on, with a bright bulge and dust lane."),
        "NGC5128": ("Centaurus A", "Radio galaxy with a supermassive black hole jet."),
        "NGC0253": ("Sculptor Galaxy", "Starburst spiral."),
    ]
    static let positionAngle: [String: Double] = ["MESSIER031": 38, "MESSIER033": 23, "LMC": 170, "SMC": 45, "MESSIER081": 157, "MESSIER082": 65, "MESSIER101": 39, "NGC5194": 163, "NGC4594": 90, "NGC0253": 52, "NGC5128": 35]
    static let namedStars: Set<String> = ["Sirius", "Rigil Kentaurus", "Proxima Centauri", "Barnard's Star", "Vega", "Arcturus", "Betelgeuse", "Rigel", "Polaris", "Deneb", "Antares", "Aldebaran", "Canopus", "Altair", "Spica", "Procyon", "Capella", "Fomalhaut", "Regulus", "Mirach"]

    struct LCG {
        var s: UInt32
        mutating func next() -> Double { s = s &* 1_664_525 &+ 1_013_904_223; return Double(s) / 4_294_967_296 }
        mutating func gauss() -> Double { sqrt(-2 * log(next() + 1e-9)) * cos(2 * .pi * next()) }
    }

    // MARK: Build

    static func load(date: Date = Date(), bundle: Bundle = .main) -> Catalog {
        var cat = Catalog()
        let t = (date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545) / 36_525

        cat.layers.append(Layer(name: "sun", points: [Point(position: .zero, absMag: 4.83, diameter: 0.0000465 * 2, tint: [1, 0.95, 0.85])], limit: 6, exposure: 0))
        cat.places.append(Place(name: "Sun", position: .zero, view: 50 * au, kind: "Star · G2V", note: "Our star. Everything here is measured from it.", showWithin: 2e5))
        var planetPoints: [Point] = []
        for p in planets {
            let pos = position(of: p, t: t)
            planetPoints.append(Point(position: SIMD3<Float>(pos), absMag: 27, diameter: 3e-7, tint: p.tint))
            cat.places.append(Place(name: p.name, position: pos, view: p.el[0] * 0.6 * au, kind: "Planet",
                                    note: "\(p.el[0].formatted(.number.precision(.fractionLength(2)))) AU from the Sun · position for today, NASA JPL elements",
                                    showWithin: p.el[0] * 80 * au))
            cat.orbits.append(Orbit(name: p.name, points: (0...256).map { k in SIMD3<Float>(position(of: p, t: t, meanAnomaly: -180 + 360 * Double(k) / 256)) }, tint: p.tint))
        }
        cat.layers.append(Layer(name: "planets", points: planetPoints, limit: 6, exposure: 0))

        // Stars: HYG v4.1.
        if let data = try? Data(contentsOf: bundle.url(forResource: "stars", withExtension: "bin")!) {
            let f = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let n = f.count / 5
            var pts: [Point] = []
            pts.reserveCapacity(n)
            for i in 0..<n {
                pts.append(Point(position: SIMD3(f[i * 5], f[i * 5 + 1], f[i * 5 + 2]), absMag: f[i * 5 + 3], diameter: 0.0000465 * 2,
                                 seed: Float(i % 997) / 997 + 0.001, tint: bvToRGB(Double(f[i * 5 + 4]))))
            }
            cat.layers.append(Layer(name: "stars", points: pts, limit: 7.5, exposure: 0.35))
            if let nd = try? Data(contentsOf: bundle.url(forResource: "stars", withExtension: "json")!),
               let names = try? JSONSerialization.jsonObject(with: nd) as? [[Any]] {
                for row in names {
                    guard let i = row[0] as? Int, let name = row[1] as? String, namedStars.contains(name), i < n else { continue }
                    let p = SIMD3<Double>(pts[i].position)
                    let d = simd_length(p)
                    cat.places.append(Place(name: name, position: p, view: max(0.05, d * 0.05), kind: "Star",
                                            note: "\(distanceText(d)) from the Sun · HYG v4.1 (Hipparcos)", showWithin: max(40, d * 6), minView: 0.02))
                }
            }
        }

        // The Milky Way: a model, because nobody has photographed it from outside.
        do {
            var r = LCG(s: 42), pts: [Point] = []
            let pitch = tan(12 * Double.pi / 180)
            while pts.count < 30_000 {
                var x = 0.0, y = 0.0, z = 0.0, warm = 0.0
                let kind = r.next()
                if kind < 0.12 {
                    let l = r.gauss() * 1800, w = r.gauss() * 600, a = 27 * Double.pi / 180
                    x = l * cos(a) - w * sin(a); y = l * sin(a) + w * cos(a); z = r.gauss() * 350; warm = 1
                } else if kind < 0.62 {
                    let arm = floor(r.next() * 4), rad = 3000 + 12000 * pow(r.next(), 1.3)
                    let th = arm * .pi / 2 + log(rad / 3000) / pitch + r.gauss() * 0.12
                    x = -rad * cos(th) + r.gauss() * 250; y = -rad * sin(th) + r.gauss() * 250; z = r.gauss() * 120
                } else {
                    let rad = -2600 * log(1 - r.next() * 0.995), th = r.next() * .pi * 2
                    x = rad * cos(th); y = rad * sin(th); z = r.gauss() * 300; warm = 0.6
                }
                if simd_length(SIMD3(x + sunR, y, z)) < 600 { continue }
                pts.append(Point(position: SIMD3<Float>(galactocentric(x, y, z)), absMag: Float(-9.6 + r.gauss() * 0.6), diameter: 120,
                                 tint: warm > 0 ? [1, 0.82, 0.6] : [0.7, 0.8, 1]))
            }
            cat.layers.append(Layer(name: "milky-way", points: pts, limit: 7.5, exposure: 0.35, gainInside: 0.05))
            cat.places.append(Place(name: "Milky Way", position: galactocentric(0, 0, 0), view: 60_000, kind: "Our galaxy · model",
                                    note: "Model, not a photo: bar, four arms, exponential disc. Sun 8.18 kpc from the centre (GRAVITY 2019).", showWithin: 6e6, minView: 800,
                                    facing: facing(normal: galactic * SIMD3(0, 0, 1), at: galactocentric(0, 0, 0)), radius: 15_000))
        }

        // Nearby galaxies, measured distances (UNGC).
        if let ld = try? Data(contentsOf: bundle.url(forResource: "local", withExtension: "json")!),
           let rows = try? JSONSerialization.jsonObject(with: ld) as? [[Any]] {
            var pts: [Point] = [], model: [Point] = []
            var r = LCG(s: 7)
            for row in rows {
                guard let name = row[0] as? String, name != "Milky Way",
                      let x = (row[1] as? NSNumber)?.doubleValue, let y = (row[2] as? NSNumber)?.doubleValue, let z = (row[3] as? NSNumber)?.doubleValue,
                      let d = (row[4] as? NSNumber)?.doubleValue, let inc = (row[5] as? NSNumber)?.doubleValue,
                      let bmag = (row[6] as? NSNumber)?.doubleValue, let tt = (row[7] as? NSNumber)?.intValue else { continue }
                let c = SIMD3(x, y, z)
                pts.append(Point(position: SIMD3<Float>(c), absMag: Float(bmag), diameter: Float(d > 0 ? d : 1000),
                                 tint: tt <= 0 ? [1, 0.85, 0.65] : tt >= 9 ? [0.65, 0.78, 1] : [0.9, 0.9, 1]))
                if name == "MESSIER033" { cat.m33 = c }
                let f = friendly[name]
                guard f != nil || bmag < -19.5 else { continue }
                var h = 0
                for u in name.unicodeScalars { h = (h * 31 + Int(u.value)) % 360 }
                let (major, minor, normal) = discBasis(c, pa: positionAngle[name] ?? Double(h), inc: inc > 0 ? inc : 45)
                cat.places.append(Place(name: f?.0 ?? name, position: c, view: name == "MESSIER033" ? 7000 : max(d * 2.2, 3000), kind: "Galaxy",
                                        note: "\(f.map { $0.1 + " " } ?? "")\(distanceText(simd_length(c))) away · \((d / 1000).formatted(.number.precision(.fractionLength(1)))) kpc across · UNGC",
                                        showWithin: max(d * 300, 2e6), minView: 800, facing: facing(normal: normal, at: c), radius: d / 2))
                guard d > 0 else { continue }
                let rad = d / 2, hR = rad / 3.2, per = 6000, each = bmag + 2.5 * log10(Double(per))
                var made = 0
                while made < per {
                    var a = 0.0, b = 0.0, w = 0.0, warm = 0.0
                    if tt <= 0 {
                        a = r.gauss() * rad * 0.5; b = r.gauss() * rad * 0.5; w = r.gauss() * rad * 0.42; warm = 1
                    } else if tt >= 9 {
                        let cl = floor(r.next() * 9), ca = cl * 2.4, cr = rad * 0.5 * sqrt((cl + 1) / 9)
                        a = cr * cos(ca) + r.gauss() * rad * 0.18; b = cr * sin(ca) + r.gauss() * rad * 0.18; w = r.gauss() * rad * 0.05
                    } else {
                        let r0 = r.next()
                        if r0 < 0.15 { a = r.gauss() * hR * 0.4; b = r.gauss() * hR * 0.4; w = r.gauss() * hR * 0.3; warm = 1 }
                        else {
                            let rr = -hR * log(1 - r.next() * 0.97), arm = r0 < 0.6 ? floor(r.next() * 2) : -1
                            let th = arm < 0 ? r.next() * .pi * 2 : arm * .pi + log(max(rr, hR * 0.2) / (hR * 0.2)) / 0.32 + r.gauss() * 0.18
                            a = rr * cos(th); b = rr * sin(th); w = r.gauss() * hR * 0.06; warm = arm < 0 ? 0.5 : 0
                        }
                    }
                    if name == "MESSIER033" && abs(a) < 2150 && abs(b) < 1210 { continue } // the Hubble mosaic covers this
                    made += 1
                    let p = c + major * a + minor * b + normal * w
                    model.append(Point(position: SIMD3<Float>(p), absMag: Float(each + r.gauss() * 0.5), diameter: Float(rad * 0.008),
                                       tint: warm == 1 ? [1, 0.84, 0.64] : warm > 0 ? [0.92, 0.9, 1] : [0.66, 0.78, 1]))
                }
            }
            if let m33 = cat.m33 {
                let (major, minor, normal) = discBasis(m33, pa: 23, inc: 54)
                let w = 14_000 * lightYear, h = w / Double(M33.mosaicAspect)
                for lm in M33.landmarks where lm.id != "centre" {
                    guard let uv = lm.mapUV else { continue }
                    let p = m33 + major * (Double(uv.x) - 0.5) * w + minor * (0.5 - Double(uv.y)) * h
                    cat.places.append(Place(name: lm.name, position: p, view: lm.sizeLy * lightYear * 3, kind: "In M33 · Hubble mosaic",
                                            note: lm.detail, showWithin: 30_000, minView: 0, facing: facing(normal: normal, at: m33)))
                }
            }
            cat.layers.append(Layer(name: "local", points: pts, limit: 12, exposure: 0.45))
            cat.layers.append(Layer(name: "galaxy-models", points: model.map { var p = $0; p.gain = 0.04; return p }, limit: 12, exposure: 0.3))
        }

        // 2MASS Redshift Survey: the cosmic web.
        if let data = try? Data(contentsOf: bundle.url(forResource: "survey", withExtension: "bin")!) {
            let f = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let pts = (0..<(f.count / 4)).map { i in
                Point(position: SIMD3(f[i * 4], f[i * 4 + 1], f[i * 4 + 2]), absMag: f[i * 4 + 3] + 3, diameter: 25_000, gain: 0.3, tint: [0.95, 0.8, 0.62])
            }
            cat.layers.append(Layer(name: "survey", points: pts, limit: 12, exposure: 0.55))
            cat.places.append(Place(name: "Cosmic web", position: .zero, view: 4.5e8, kind: "2MASS Redshift Survey",
                                    note: "\(pts.count.formatted()) galaxies placed by redshift (H0 = 70). Dark wedges are where our own galaxy blocks the view.", showWithin: 0))
        }
        return cat
    }
}
