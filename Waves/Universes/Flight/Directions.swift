// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes directions, like Google Maps for space: milestones on the straight path between two places,
// travel time by light (real) and by spacetime bubble (a hypothetical warp drive), and rabbitholes, the
// wormhole network. Same rules as khensu-site src/scripts/universes/route.ts. Spec: design/nu-universes.md §15.

import Foundation
import simd

enum Directions {
    enum Opens: Hashable { case always, sky, visited(String) }
    struct Gate { var place: String; var name: String; var opens: Opens; var links: [String] }

    /// Gates sit at places. A jump runs along a link, and both ends must be open to you.
    static let gates: [Gate] = [
        .init(place: "Sun", name: "Sol", opens: .always, links: ["Rigil Kentaurus", "Milky Way"]),
        .init(place: "Rigil Kentaurus", name: "Alpha Centauri", opens: .always, links: ["Sun"]),
        .init(place: "Milky Way", name: "Sagittarius A*", opens: .always, links: ["Sun", "Large Magellanic Cloud", "Small Magellanic Cloud", "Andromeda Galaxy · M31", "Centaurus A", "Bode's Galaxy · M81"]),
        .init(place: "Large Magellanic Cloud", name: "LMC", opens: .sky, links: ["Milky Way", "Small Magellanic Cloud"]),
        .init(place: "Small Magellanic Cloud", name: "SMC", opens: .sky, links: ["Milky Way", "Large Magellanic Cloud"]),
        .init(place: "Andromeda Galaxy · M31", name: "Andromeda", opens: .sky, links: ["Milky Way", "Triangulum Galaxy · M33", "M32", "M110"]),
        .init(place: "M32", name: "M32", opens: .visited("Andromeda Galaxy · M31"), links: ["Andromeda Galaxy · M31"]),
        .init(place: "M110", name: "M110", opens: .visited("Andromeda Galaxy · M31"), links: ["Andromeda Galaxy · M31"]),
        .init(place: "Triangulum Galaxy · M33", name: "Triangulum", opens: .sky, links: ["Andromeda Galaxy · M31", "NGC 604"]),
        .init(place: "NGC 604", name: "NGC 604", opens: .visited("Triangulum Galaxy · M33"), links: ["Triangulum Galaxy · M33"]),
        .init(place: "Centaurus A", name: "Centaurus A", opens: .visited("Centaurus A"), links: ["Milky Way", "Sombrero Galaxy · M104"]),
        .init(place: "Sombrero Galaxy · M104", name: "Sombrero", opens: .visited("Sombrero Galaxy · M104"), links: ["Centaurus A"]),
        .init(place: "Bode's Galaxy · M81", name: "Bode's", opens: .visited("Bode's Galaxy · M81"), links: ["Milky Way", "Cigar Galaxy · M82", "Pinwheel Galaxy · M101"]),
        .init(place: "Cigar Galaxy · M82", name: "Cigar", opens: .visited("Bode's Galaxy · M81"), links: ["Bode's Galaxy · M81"]),
        .init(place: "Pinwheel Galaxy · M101", name: "Pinwheel", opens: .visited("Pinwheel Galaxy · M101"), links: ["Bode's Galaxy · M81", "Whirlpool Galaxy · M51"]),
        .init(place: "Whirlpool Galaxy · M51", name: "Whirlpool", opens: .visited("Whirlpool Galaxy · M51"), links: ["Pinwheel Galaxy · M101"]),
    ]

    /// Where you are on Earth and where you have been; both stay on the device.
    struct Traveller { var lat: Double?; var lon: Double?; var visited: Set<String>; var now: Date }

    struct Step: Identifiable {
        let id = UUID()
        var text: String
        var detail: String
        var position: SIMD3<Double>
        var view: Double
        var along: Double
        var jump = false
        var place: Flight.Place?

        var asPlace: Flight.Place {
            place ?? Flight.Place(name: text, position: position, view: view, kind: "Directions", note: detail, showWithin: 0)
        }
    }
    struct Leg { var from: SIMD3<Double>; var to: SIMD3<Double>; var jump: Bool }
    struct Route { var steps: [Step]; var legs: [Leg]; var bubble: Double; var direct: Double; var jumps: Int; var notes: [String] }

    private static let rad = Double.pi / 180
    private static let toGalactic = Flight.galactic.transpose

    /// Right ascension (hours) and declination (deg) of a direction from the Sun.
    static func raDec(_ v: SIMD3<Double>) -> (Double, Double) {
        let n = simd_normalize(v)
        return ((atan2(n.y, n.x) / rad + 360).truncatingRemainder(dividingBy: 360) / 15, asin(n.z) / rad)
    }

    static func galactic(_ v: SIMD3<Double>) -> (Double, Double) {
        let g = toGalactic * simd_normalize(v)
        return ((atan2(g.y, g.x) / rad + 360).truncatingRemainder(dividingBy: 360), asin(g.z) / rad)
    }

    /// Altitude (deg) of a place above the horizon at latitude/longitude (deg, east positive) and time.
    static func altitude(_ pos: SIMD3<Double>, lat: Double, lon: Double, at t: Date) -> Double {
        let (ra, dec) = raDec(pos)
        let jd = t.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let lst = (280.46061837 + 360.98564736629 * (jd - 2_451_545) + lon).truncatingRemainder(dividingBy: 360)
        let h = (lst - ra * 15) * rad
        return asin(sin(lat * rad) * sin(dec * rad) + cos(lat * rad) * cos(dec * rad) * cos(h)) / rad
    }

    static func nextRise(_ pos: SIMD3<Double>, lat: Double, lon: Double, from: Date) -> Date? {
        stride(from: 10, through: 1440, by: 10).lazy.map { from.addingTimeInterval(Double($0) * 60) }
            .first { altitude(pos, lat: lat, lon: lon, at: $0) > 0 }
    }

    static func state(_ g: Gate, places: [String: Flight.Place], who: Traveller) -> (open: Bool, why: String) {
        switch g.opens {
        case .always:
            return (true, "Always open")
        case .visited(let need):
            return who.visited.contains(need) ? (true, "Open: you have been to \(need)") : (false, "Opens once you have been to \(need)")
        case .sky:
            guard let p = places[g.place] else { return (false, "Not on the map") }
            guard let lat = who.lat, let lon = who.lon else {
                return (false, "Opens while \(g.name) is above your horizon. Add your location (it stays on this device).")
            }
            let alt = altitude(p.position, lat: lat, lon: lon, at: who.now)
            if alt > 0 { return (true, "Open: \(g.name) is \(Int(alt.rounded()))° above your horizon") }
            if let rise = nextRise(p.position, lat: lat, lon: lon, from: who.now) {
                return (false, "Opens when \(g.name) rises at \(rise.formatted(date: .omitted, time: .shortened))")
            }
            return (false, "\(g.name) never rises at your latitude")
        }
    }

    private static func heading(_ dir: SIMD3<Double>) -> String {
        let (ra, dec) = raDec(dir), (l, b) = galactic(dir)
        let h = Int(ra), m = Int(((ra - Double(h)) * 60).rounded())
        func f(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) }
        return "Head toward RA \(h)h \(String(format: "%02d", m))m, Dec \(dec >= 0 ? "+" : "−")\(f(abs(dec)))° · galactic l \(f(l))°, b \(b >= 0 ? "+" : "−")\(f(abs(b)))°"
    }

    private static func inDisc(_ p: SIMD3<Double>) -> Bool {
        let g = toGalactic * p
        return hypot(g.x - Flight.sunR, g.y) < 15_000 && abs(g.z + Flight.sunZ) < 1_000
    }

    private static func orbit(_ name: String, _ au: Double, _ note: String) -> (r: Double, out: String, note: String, inward: String) {
        (au * Flight.au, "Cross \(name)’s orbit", note, "Cross \(name)’s orbit")
    }
    private static let shells: [(r: Double, out: String, note: String, inward: String)] = [
        orbit("Mercury", 0.387, "The innermost planet, 58 million km from the Sun."),
        orbit("Venus", 0.723, "The hottest planet, under clouds of sulphuric acid."),
        orbit("Earth", 1, "Home: 150 million km from the Sun, 8 light-minutes."),
        orbit("Mars", 1.524, "The red planet, 12.7 light-minutes from the Sun."),
        (2.2 * Flight.au, "Enter the asteroid belt", "Millions of rocks, but so spread out that spacecraft cross without dodging.", "Leave the asteroid belt"),
        (3.3 * Flight.au, "Leave the asteroid belt", "Next is Jupiter, more than twice as massive as all the other planets together.", "Enter the asteroid belt"),
        orbit("Jupiter", 5.203, "The largest planet; its gravity shapes the asteroid belt."),
        orbit("Saturn", 9.537, "The ringed planet, 80 light-minutes from the Sun."),
        orbit("Uranus", 19.19, "The ice giant that rolls on its side."),
        (30.07 * Flight.au, "Cross Neptune’s orbit into the Kuiper belt", "The last planet. Beyond it, the icy Kuiper belt, home of Pluto.", "Cross Neptune’s orbit"),
        (50 * Flight.au, "Leave the Kuiper belt", "Past the main belt of icy worlds; scattered objects like Eris and Sedna roam beyond.", "Enter the Kuiper belt"),
        (120 * Flight.au, "Cross the heliopause", "The solar wind ends and interstellar space begins (Voyager 1, 2012).", "Cross the heliopause into the Sun’s wind"),
        (2_000 * Flight.au, "Enter the Oort cloud", "The inner edge of the Sun’s shell of comets, roughly 2,000 AU out. Nobody has seen it directly; long-period comets show it is there.", "Leave the Oort cloud"),
        (100_000 * Flight.au, "Leave the Oort cloud", "The outer edge of the Sun’s comets, about 1.6 light-years out.", "Enter the Oort cloud"),
        (150, "Leave the Local Bubble", "The hot cavity, about 1,000 light-years across, blown by supernovae around the Sun.", "Enter the Local Bubble"),
    ]

    /// Milestones on the straight path from a to b.
    static func bubbleSteps(_ a: Flight.Place, _ b: Flight.Place, places: [Flight.Place]) -> [Step] {
        let d = simd_distance(a.position, b.position)
        guard d > 0 else { return [] }
        let dir = simd_normalize(b.position - a.position)
        func at(_ s: Double) -> SIMD3<Double> { a.position + dir * s }
        // Sample in log distance from both ends, so an AU-scale shell is found on a megaparsec trip.
        var set: Set<Double> = [0, d]
        for k in 0...600 {
            let s = 1e-7 * pow(d / 1e-7, Double(k) / 600)
            if s < d { set.insert(s); set.insert(d - s) }
        }
        let ss = set.sorted()
        let ra = simd_length(a.position), rb = simd_length(b.position)
        let regions = places.filter { $0.radius != nil && $0 != a && $0 != b && $0.name != "Milky Way" }
        var steps = [Step(text: "Leave \(a.name)", detail: heading(dir), position: a.position, view: a.view, along: 0, place: a)]
        for i in 1..<ss.count {
            let p0 = at(ss[i - 1]), p1 = at(ss[i])
            let r0 = simd_length(p0), r1 = simd_length(p1)
            for sh in shells where (r0 - sh.r) * (r1 - sh.r) < 0 && abs(ra - sh.r) > 0.05 * sh.r && abs(rb - sh.r) > 0.05 * sh.r {
                steps.append(Step(text: r1 > r0 ? sh.out : sh.inward, detail: sh.note, position: p1, view: max(sh.r * 2, 1e-4), along: ss[i]))
            }
            let d0 = inDisc(p0), d1 = inDisc(p1)
            if d0 != d1 {
                steps.append(Step(text: d0 ? "Leave the Milky Way’s disc" : "Enter the Milky Way’s disc",
                                  detail: d0 ? "Out of the stars and gas of our galaxy, into intergalactic space." : "Into the stars and gas of our galaxy.",
                                  position: p1, view: 30_000, along: ss[i]))
            }
            for g in regions {
                let in0 = simd_distance(p0, g.position) < g.radius!, in1 = simd_distance(p1, g.position) < g.radius!
                if in0 != in1 { steps.append(Step(text: "\(in1 ? "Enter" : "Leave") \(g.name)", detail: g.note, position: p1, view: g.view, along: ss[i], place: g)) }
            }
        }
        for g in regions {
            let t = min(max(simd_dot(g.position - a.position, dir), 0), d)
            let miss = simd_distance(at(t), g.position)
            if t > 0, t < d, miss > g.radius!, miss < g.radius! * 3 {
                steps.append(Step(text: "Pass \(g.name)", detail: "\(Flight.distanceText(miss)) off your path. \(g.note)", position: g.position, view: g.view, along: t, place: g))
            }
        }
        steps.append(Step(text: "Arrive at \(b.name)", detail: b.note, position: b.position, view: b.view, along: d, place: b))
        return steps.sorted { $0.along < $1.along }
    }

    static func bubbleRoute(_ a: Flight.Place, _ b: Flight.Place, places: [Flight.Place]) -> Route {
        let d = simd_distance(a.position, b.position)
        return Route(steps: bubbleSteps(a, b, places: places), legs: [Leg(from: a.position, to: b.position, jump: false)], bubble: d, direct: d, jumps: 0, notes: [])
    }

    /// The best rabbithole route: least bubble travel through open gates, fewest jumps on ties.
    static func rabbitholeRoute(_ a: Flight.Place, _ b: Flight.Place, places: [Flight.Place], who: Traveller) -> Route {
        let byName = Dictionary(places.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        let live = gates.filter { byName[$0.place] != nil }
        let gateNamed = Dictionary(live.map { ($0.place, $0) }, uniquingKeysWith: { x, _ in x })
        let states = Dictionary(live.map { ($0.place, state($0, places: byName, who: who)) }, uniquingKeysWith: { x, _ in x })
        let direct = simd_distance(a.position, b.position)

        func best(openOnly: Bool) -> (cost: Double, path: [Gate]) {
            let ok = { (g: Gate) in !openOnly || states[g.place]!.open }
            var best: (cost: Double, path: [Gate]) = (direct, [])
            for g0 in live where ok(g0) {
                var prev: [String: String?] = [g0.place: nil]
                var queue = [g0]
                while !queue.isEmpty {
                    let g = queue.removeFirst()
                    for n in g.links {
                        if let gn = gateNamed[n], ok(gn), prev[n] == nil { prev[n] = .some(g.place); queue.append(gn) }
                    }
                }
                for end in prev.keys where end != g0.place {
                    let cost = simd_distance(a.position, byName[g0.place]!.position) + simd_distance(byName[end]!.position, b.position)
                    var path: [Gate] = []
                    var n: String? = end
                    while let cur = n { path.insert(gateNamed[cur]!, at: 0); n = prev[cur] ?? nil }
                    if cost < best.cost * 0.999 || (abs(cost - best.cost) < best.cost * 1e-3 && !best.path.isEmpty && path.count < best.path.count) {
                        best = (cost, path)
                    }
                }
            }
            return best
        }

        let open = best(openOnly: true), ideal = best(openOnly: false)
        let notes = ideal.path.compactMap { g in states[g.place]!.open ? nil : "\(g.name) rabbithole: \(states[g.place]!.why)" }
        guard let firstGate = open.path.first, let lastGate = open.path.last else {
            var r = bubbleRoute(a, b, places: places)
            r.notes = notes.isEmpty ? ["No open rabbithole shortens this trip."] : notes
            return r
        }
        let first = byName[firstGate.place]!, last = byName[lastGate.place]!
        var steps: [Step] = [], legs: [Leg] = []
        var along = 0.0
        if first != a, simd_distance(a.position, first.position) > 0 {
            for var s in bubbleSteps(a, first, places: places) {
                if s.place == first { s.text = "Reach the \(firstGate.name) rabbithole" }
                steps.append(s)
            }
            legs.append(Leg(from: a.position, to: first.position, jump: false))
            along = simd_distance(a.position, first.position)
        } else {
            steps.append(Step(text: "Enter the \(firstGate.name) rabbithole", detail: states[firstGate.place]!.why, position: first.position, view: first.view, along: 0, place: first))
        }
        for i in 1..<open.path.count {
            let g0 = byName[open.path[i - 1].place]!, g1 = byName[open.path[i].place]!
            let name = open.path[i].name
            steps.append(Step(text: g1 == b ? "Jump to \(name): you have arrived" : "Jump to \(name)",
                              detail: "\(Flight.distanceText(simd_distance(g0.position, g1.position))) in no time. \(states[g1.name]!.why).",
                              position: g1.position, view: g1.view, along: along, jump: true, place: g1))
            legs.append(Leg(from: g0.position, to: g1.position, jump: true))
        }
        if last != b, simd_distance(last.position, b.position) > 0 {
            for var s in bubbleSteps(last, b, places: places).dropFirst() { s.along += along; steps.append(s) }
            legs.append(Leg(from: last.position, to: b.position, jump: false))
        }
        return Route(steps: steps, legs: legs, bubble: open.cost, direct: direct, jumps: open.path.count - 1, notes: notes)
    }

    static func years(_ pc: Double, timesLight: Double) -> Double { pc / Flight.lightYear / timesLight }

    /// Parker Solar Probe's record, 191.7 km/s on 24 December 2024: the fastest any spacecraft has gone.
    static let spacecraftKms = 191.7
    static let spacecraft = spacecraftKms / 299_792.458

    static func durationText(years y: Double) -> String {
        let s = y * 365.25 * 86_400
        func f(_ v: Double, _ d: Int) -> String { v.formatted(.number.precision(.fractionLength(d))) }
        if s == 0 { return "instant" }
        if s < 1 { return "under a second" }
        if s < 60 { return "\(Int(s.rounded())) s" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min" }
        if s < 86_400 { return "\(f(s / 3600, s < 36_000 ? 1 : 0)) h" }
        if y < 1 { let d = Int((s / 86_400).rounded()); return "\(d) day\(d == 1 ? "" : "s")" }
        if y < 1000 { return "\(y < 10 ? f(y, 1) : f(y, 0)) years" }
        if y < 1e6 { return "\(f(y / 1e3, y < 1e4 ? 1 : 0)) thousand years" }
        if y < 1e9 { return "\(f(y / 1e6, y < 1e7 ? 2 : 1)) million years" }
        return "\(f(y / 1e9, 2)) billion years"
    }
}
