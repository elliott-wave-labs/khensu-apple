// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes directions, laid out like Google Maps: From, To, how you travel, how long, the steps, then the
// fine print. Your location, the places you have visited and your last place stay on this device (UserDefaults).

import SwiftUI
import CoreLocation
import simd

@MainActor @Observable
final class DirectionsModel: NSObject, CLLocationManagerDelegate {
    enum Mode: String, CaseIterable, Identifiable {
        case rabbithole = "Rabbitholes", bubble = "Bubble", light = "Light", craft = "Spacecraft"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .rabbithole: "tornado"
            case .bubble: "circle.circle"
            case .light: "bolt"
            case .craft: "airplane.departure"
            }
        }
        var text: String {
            switch self {
            case .rabbithole: "Rabbitholes, with the spacetime bubble between them"
            case .bubble: "Spacetime bubble"
            case .light: "Light speed"
            case .craft: "Fastest spacecraft"
            }
        }
    }
    static let speeds: [(String, Double)] = [("1× light speed", 1), ("1,000× light speed", 1e3), ("1 million× light speed", 1e6),
                                             ("1 billion× light speed", 1e9), ("1 trillion× light speed", 1e12)]

    let places: [Flight.Place]
    weak var rig: FlightRig?
    var from: Flight.Place? { didSet { stop(); refresh() } }
    var to: Flight.Place? { didSet { stop(); refresh() } }
    var mode = Mode.rabbithole { didSet { stop(); refresh() } }
    var speed = 1e9 { didSet { refresh() } }
    var lat: Double? { didSet { saveWhere() } }
    var lon: Double? { didSet { saveWhere() } }
    private(set) var visited: Set<String>
    private(set) var route: Directions.Route?
    private(set) var times: [Mode: String] = [:]
    private(set) var duration = ""
    private(set) var summary = ""
    private(set) var warning = ""
    private(set) var current: Int?
    private(set) var playing = false
    var locating = false
    private var here: Flight.Place?
    private let location = CLLocationManager()
    private let defaults = UserDefaults.standard

    init(places: [Flight.Place], rig: FlightRig) {
        self.places = places
        self.rig = rig
        visited = Set(defaults.stringArray(forKey: "universes.visited") ?? [])
        if let w = defaults.array(forKey: "universes.where") as? [Double], w.count == 2 { lat = w[0]; lon = w[1] }
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyReduced
        rig.onArrive = { [weak self] p in self?.arrived(p) }
    }

    /// Where you are now: the last place you arrived at (this visit, then any visit), else Earth.
    var currentPlace: Flight.Place? {
        here ?? defaults.string(forKey: "universes.last").flatMap { n in places.first { $0.name == n } } ?? places.first { $0.name == "Earth" }
    }

    var traveller: Directions.Traveller { .init(lat: lat, lon: lon, visited: visited, now: Date()) }

    var openGates: [Directions.Gate] {
        let byName = Dictionary(places.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        return Directions.gates.filter { byName[$0.place] != nil && Directions.state($0, places: byName, who: traveller).open }
    }
    var liveGateCount: Int { Directions.gates.filter { g in places.contains { $0.name == g.place } }.count }

    func rate(_ m: Mode) -> Double { m == .light ? 1 : m == .craft ? Directions.spacecraft : speed }

    func refresh() {
        current = nil
        warning = ""
        guard let a = from, let b = to, a != b else {
            route = nil; times = [:]; duration = ""
            summary = to == nil ? "Choose where to go." : "You are already there."
            rig?.route = []
            return
        }
        let holes = Directions.rabbitholeRoute(a, b, places: places, who: traveller)
        let direct = holes.direct
        func t(_ pc: Double, _ m: Mode) -> String { Directions.durationText(years: Directions.years(pc, timesLight: rate(m))) }
        times = [.rabbithole: t(holes.bubble, .bubble), .bubble: t(direct, .bubble), .light: t(direct, .light), .craft: t(direct, .craft)]
        if mode == .rabbithole {
            route = holes
            if holes.jumps > 0 {
                duration = times[.rabbithole] == "instant" ? "Instant" : times[.rabbithole]!
                summary = "\(holes.jumps) rabbithole jump\(holes.jumps > 1 ? "s" : "")\(holes.bubble > 0 ? " and \(Flight.distanceText(holes.bubble)) by bubble" : "") · \(Flight.distanceText(direct)) as the crow flies"
            } else {
                duration = times[.bubble]!
                summary = "No open rabbithole shortens this trip, so it is all by bubble · \(Flight.distanceText(direct))"
            }
            let closed = holes.notes.filter { $0.contains("rabbithole:") }.count
            if closed > 0 { warning = "\(closed) closer rabbithole\(closed > 1 ? "s are" : " is") shut right now. See the fine print." }
        } else {
            route = Directions.bubbleRoute(a, b, places: places)
            duration = times[mode]!
            summary = "\(mode.text) · \(Flight.distanceText(direct))"
        }
        rig?.route = route?.legs ?? []
    }

    func when(_ s: Directions.Step, index: Int) -> String {
        if index == 0 { return "Start here" }
        if s.jump { return "Rabbithole jump · instant" }
        return "\(Flight.distanceText(s.along)) in · \(Directions.durationText(years: Directions.years(s.along, timesLight: rate(mode == .rabbithole ? .bubble : mode))))"
    }

    func show(_ i: Int) {
        guard let route, route.steps.indices.contains(i) else { return }
        current = i
        let s = route.steps[i]
        if s.jump { rig?.jump(to: s.asPlace) } else { rig?.fly(to: s.asPlace) }
    }

    func start() { playing = true; show(0) }
    func stop() { playing = false }
    func swap() { let a = from; from = to; to = a }
    func clear() { stop(); rig?.route = [] }

    private func arrived(_ p: Flight.Place) {
        if places.contains(p) {
            here = p
            defaults.set(p.name, forKey: "universes.last")
            if !visited.contains(p.name) {
                visited.insert(p.name)
                defaults.set(Array(visited), forKey: "universes.visited")
            }
        }
        guard playing, let route, let i = current else { return }
        guard i + 1 < route.steps.count else {
            stop()
            from = p
            to = nil
            return
        }
        let next = i + 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(route.steps[next].jump ? 600 : 1100))
            if self.playing, self.current == i { self.show(next) }
        }
    }

    private func saveWhere() {
        if let lat, let lon { defaults.set([lat, lon], forKey: "universes.where") } else { defaults.removeObject(forKey: "universes.where") }
    }

    func locate() {
        locating = true
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() } else { location.requestLocation() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            guard self.locating else { return }
            switch status {
            case .notDetermined: break
            case .denied, .restricted: self.locating = false
            default: self.location.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in
            // Two decimals, about a kilometre: plenty for a horizon.
            self.lat = (c.latitude * 100).rounded() / 100
            self.lon = (c.longitude * 100).rounded() / 100
            self.locating = false
            self.refresh()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.locating = false }
    }
}

private let cyan = Color(red: 0.49, green: 0.84, blue: 1)
private let pink = Color(red: 1, green: 0.48, blue: 0.85)
private let red = Color(red: 1, green: 0.48, blue: 0.48)

struct DirectionsView: View {
    @Bindable var model: DirectionsModel
    var close: () -> Void
    @State private var picking: Bool?
    @State private var latText = ""
    @State private var lonText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Directions").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.glass).accessibilityLabel("Close directions")
            }
            .padding([.horizontal, .top])
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ends
                    modes
                    if model.route != nil || !model.summary.isEmpty { summary }
                    if let route = model.route { steps(route) }
                    finePrint
                }
                .padding()
            }
            Button { model.playing ? model.stop() : model.start() } label: {
                Text(model.playing ? "Stop" : "Start").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.route == nil)
            .padding()
        }
        .sheet(item: Binding(get: { picking.map { PickTarget(isFrom: $0) } }, set: { picking = $0?.isFrom })) { target in
            PlacePicker(places: model.places, title: target.isFrom ? "From" : "To") { p in
                if target.isFrom { model.from = p } else { model.to = p }
                picking = nil
            }
        }
        .onAppear {
            if model.from == nil { model.from = model.currentPlace }
            latText = model.lat.map { String($0) } ?? ""
            lonText = model.lon.map { String($0) } ?? ""
            model.refresh()
        }
        .onChange(of: model.lat) { latText = model.lat.map { String($0) } ?? "" }
        .onChange(of: model.lon) { lonText = model.lon.map { String($0) } ?? "" }
    }

    private struct PickTarget: Identifiable { var isFrom: Bool; var id: Bool { isFrom } }

    private var ends: some View {
        HStack(spacing: 10) {
            VStack(spacing: 8) {
                endRow("From", model.from?.name, placeholder: "Where you are", icon: "circle", tint: cyan) { picking = true }
                endRow("To", model.to?.name, placeholder: "Search: Moon, Europa, Ceres, Halley…", icon: "mappin.circle.fill", tint: red) { picking = false }
            }
            Button { model.swap() } label: { Image(systemName: "arrow.up.arrow.down") }
                .buttonStyle(.glass).accessibilityLabel("Swap From and To")
        }
    }

    private func endRow(_ label: String, _ value: String?, placeholder: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
                    Text(value ?? placeholder).foregroundStyle(value == nil ? .secondary : .primary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(value ?? "not set")")
    }

    private var modes: some View {
        HStack(spacing: 6) {
            ForEach(DirectionsModel.Mode.allCases) { m in
                let on = model.mode == m
                Button { model.mode = m } label: {
                    VStack(spacing: 3) {
                        Image(systemName: m.symbol).font(.body)
                        Text(m.rawValue).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                        Text(model.times[m] ?? " ").font(.caption2).foregroundStyle(on ? .black.opacity(0.7) : .secondary)
                            .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .padding(.vertical, 6)
                    .foregroundStyle(on ? .black : .primary)
                    .background(on ? Color(red: 0.86, green: 0.9, blue: 1) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !model.duration.isEmpty { Text(model.duration.prefix(1).uppercased() + model.duration.dropFirst()).font(.largeTitle.weight(.semibold)) }
            Text(model.summary).font(.subheadline).foregroundStyle(.secondary)
            if !model.warning.isEmpty { Text(model.warning).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func steps(_ route: Directions.Route) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(route.steps.enumerated()), id: \.element.id) { i, s in
                let last = i == route.steps.count - 1
                let nextJump = !last && route.steps[i + 1].jump
                Button { model.stop(); model.show(i) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack(alignment: .top) {
                            if !last {
                                Rectangle().fill(nextJump ? pink : cyan).frame(width: 3).opacity(0.55).padding(.top, 26)
                            }
                            Text("\(i + 1)")
                                .font(.caption.weight(.bold)).foregroundStyle(.black)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(last ? red : s.jump ? pink : cyan))
                        }
                        .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.text).font(.body.weight(.semibold))
                            Text(model.when(s, index: i)).font(.caption).foregroundStyle(cyan)
                            Text(s.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 14)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.top, 8)
                    .background(model.current == i ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var finePrint: some View {
        DisclosureGroup("Fine print") {
            VStack(alignment: .leading, spacing: 10) {
                fine("Rabbitholes", "Wormholes between places: a jump takes no time. Between rabbitholes you travel by spacetime bubble.")
                VStack(alignment: .leading, spacing: 4) {
                    fine("Spacetime bubble", "A warp bubble: allowed by general relativity on paper, not built. Pick how fast it goes, in multiples of light speed:")
                    Picker("Bubble speed", selection: $model.speed) {
                        ForEach(DirectionsModel.speeds, id: \.1) { s in Text(s.0).tag(s.1) }
                    }
                }
                fine("Light", "299,792 km/s: the real limit for anything with mass, so this is the fastest real trip.")
                fine("Spacecraft", "Parker Solar Probe's record, \(Directions.spacecraftKms.formatted()) km/s (24 December 2024), held the whole way. Voyager 1, the fastest thing leaving the Solar System, does about 17 km/s.")
                VStack(alignment: .leading, spacing: 6) {
                    fine("Which rabbitholes are open", "\(model.openGates.count) of \(model.liveGateCount) open to you now: \(model.openGates.map(\.name).joined(separator: ", ")). Some open only while their galaxy is above your horizon, and some once you have been there. Your location and the places you have visited stay on this device.")
                    Button(model.locating ? "Finding you…" : "Use my location") { model.locate() }
                        .disabled(model.locating)
                    HStack {
                        TextField("Latitude", text: $latText).onSubmit(applyWhere)
                        TextField("Longitude", text: $lonText).onSubmit(applyWhere)
                    }
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                }
                if let notes = model.route?.notes, !notes.isEmpty {
                    ForEach(notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
                Text("Moons are at their measured distance and period; where each is along its orbit today is approximate. Asteroids and comets: NASA/JPL Small-Body Database.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
        }
        .font(.subheadline)
    }

    private func fine(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(body).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func applyWhere() {
        let la = Double(latText), lo = Double(lonText)
        if let la, let lo, abs(la) <= 90, abs(lo) <= 180 { model.lat = la; model.lon = lo }
        else if latText.isEmpty && lonText.isEmpty { model.lat = nil; model.lon = nil }
        model.refresh()
    }
}

/// Every place, grouped like the web list: the Solar System with moons under their planets and bodies under their
/// belts, then stars, then the Milky Way and beyond. Searching flattens it.
struct PlacePicker: View {
    let places: [Flight.Place]
    let title: String
    let pick: (Flight.Place) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable { let id = UUID(); var place: Flight.Place?; var label: String; var depth: Int }

    private func parent(_ p: Flight.Place) -> String? { p.parent ?? (p.kind.hasPrefix("In M33") ? "Triangulum Galaxy · M33" : nil) }

    private var sections: [(String, [Row])] {
        var kids: [String: [Flight.Place]] = [:]
        for p in places { if let pa = parent(p) { kids[pa, default: []].append(p) } }
        func tree(_ p: Flight.Place, _ d: Int) -> [Row] { [Row(place: p, label: p.name, depth: d)] + (kids[p.name] ?? []).flatMap { tree($0, d + 1) } }
        let solar = places.filter { parent($0) == nil && simd_length($0.position) < 0.05 && $0.name != "Cosmic web" }
        var tops: [(Double, [Row])] = solar.map { p in (p.order ?? (p.name == "Sun" ? 0 : simd_length(p.position) / Flight.au), tree(p, 0)) }
        for (i, h) in ["Near-Earth asteroids", "Comets"].enumerated() {
            if let k = kids[h] { tops.append((1e4 + Double(i), [Row(place: nil, label: h, depth: 0)] + k.flatMap { tree($0, 1) })) }
        }
        let stars = places.filter { parent($0) == nil && $0.kind.hasPrefix("Star") && $0.name != "Sun" }.flatMap { tree($0, 0) }
        let beyond = places.filter { parent($0) == nil && !solar.contains($0) && !$0.kind.hasPrefix("Star") }.flatMap { tree($0, 0) }
        return [("Solar System", tops.sorted { $0.0 < $1.0 }.flatMap(\.1)), ("Stars", stars), ("Milky Way and beyond", beyond)]
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    ForEach(sections, id: \.0) { name, rows in
                        Section(name) { ForEach(rows) { row($0) } }
                    }
                } else {
                    let q = query.lowercased()
                    ForEach(places.filter { $0.name.lowercased().contains(q) || $0.kind.lowercased().contains(q) }.prefix(80), id: \.name) { p in
                        row(Row(place: p, label: p.name, depth: 0))
                    }
                }
            }
            .searchable(text: $query, prompt: "Moon, Europa, Ceres, Halley, Andromeda…")
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 520)
        #endif
    }

    @ViewBuilder private func row(_ r: Row) -> some View {
        if let p = r.place {
            Button { pick(p) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name)
                    Text(p.kind).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(r.depth) * 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text(r.label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}
