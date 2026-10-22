// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes directions sheet: From/To, three ways to travel, a step list you can tap or play.
// Your location and the places you have visited stay on this device (UserDefaults) and are never sent.

import SwiftUI
import CoreLocation

@MainActor @Observable
final class DirectionsModel: NSObject, CLLocationManagerDelegate {
    enum Mode: String, CaseIterable, Identifiable { case rabbithole = "Rabbitholes", bubble = "Bubble", light = "Light"; var id: Self { self } }
    static let speeds: [(String, Double)] = [("1×", 1), ("1,000×", 1e3), ("1 million×", 1e6), ("1 billion×", 1e9), ("1 trillion×", 1e12)]

    let places: [Flight.Place]
    weak var rig: FlightRig?
    var from: Flight.Place?
    var to: Flight.Place?
    var mode = Mode.rabbithole { didSet { stop(); refresh() } }
    var speed = 1e9 { didSet { refresh() } }
    var lat: Double? { didSet { saveWhere() } }
    var lon: Double? { didSet { saveWhere() } }
    private(set) var visited: Set<String>
    private(set) var route: Directions.Route?
    private(set) var times: [Mode: String] = [:]
    private(set) var current: Int?
    private(set) var playing = false
    var locating = false
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

    var traveller: Directions.Traveller { .init(lat: lat, lon: lon, visited: visited, now: Date()) }

    var openGates: [Directions.Gate] {
        let byName = Dictionary(places.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        return Directions.gates.filter { byName[$0.place] != nil && Directions.state($0, places: byName, who: traveller).open }
    }
    var liveGateCount: Int { Directions.gates.filter { g in places.contains { $0.name == g.place } }.count }

    func refresh() {
        current = nil
        guard let a = from, let b = to, a != b else { route = nil; times = [:]; rig?.route = []; return }
        let holes = Directions.rabbitholeRoute(a, b, places: places, who: traveller)
        let direct = holes.direct
        times = [.light: Directions.durationText(years: Directions.years(direct, timesLight: 1)),
                 .bubble: Directions.durationText(years: Directions.years(direct, timesLight: speed)),
                 .rabbithole: holes.jumps > 0 ? Directions.durationText(years: Directions.years(holes.bubble, timesLight: speed)) : "—"]
        switch mode {
        case .rabbithole:
            var r = holes
            if r.jumps > 0 {
                let by = r.bubble > 0 ? "\(Flight.distanceText(r.bubble)) by bubble" : "no bubble travel at all"
                r.notes.insert("\(r.jumps) jump\(r.jumps > 1 ? "s" : "") through rabbitholes, \(by) instead of \(Flight.distanceText(direct)).", at: 0)
            }
            route = r
        case .bubble:
            var r = Directions.bubbleRoute(a, b, places: places)
            r.notes = ["A spacetime bubble at \(Self.speeds.first { $0.1 == speed }?.0 ?? "") light speed: \(times[.bubble]!). Warp bubbles are allowed by general relativity on paper, not built."]
            route = r
        case .light:
            var r = Directions.bubbleRoute(a, b, places: places)
            r.notes = ["Real light takes \(times[.light]!). Nothing with mass gets there faster without new physics."]
            route = r
        }
        rig?.route = route?.legs ?? []
    }

    func when(_ s: Directions.Step, index: Int) -> String {
        if index == 0 { return "Start" }
        if s.jump { return "Jump · no time" }
        return "\(Flight.distanceText(s.along)) · \(Directions.durationText(years: Directions.years(s.along, timesLight: mode == .light ? 1 : speed)))"
    }

    func show(_ i: Int) {
        guard let route, route.steps.indices.contains(i) else { return }
        current = i
        let s = route.steps[i]
        if s.jump { rig?.jump(to: s.asPlace) } else { rig?.fly(to: s.asPlace) }
    }

    func start() { playing = true; show(0) }
    func stop() { playing = false }
    func swap() { (from, to) = (to, from); stop(); refresh() }
    func clear() { stop(); rig?.route = [] }

    private func arrived(_ p: Flight.Place) {
        if places.contains(p), !visited.contains(p.name) {
            visited.insert(p.name)
            defaults.set(Array(visited), forKey: "universes.visited")
        }
        guard playing, let route, let i = current else { return }
        guard i + 1 < route.steps.count else { stop(); refresh(); return }
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

struct DirectionsView: View {
    @Bindable var model: DirectionsModel
    var close: () -> Void
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
            List {
                Section {
                    placePicker("From", selection: $model.from)
                    placePicker("To", selection: $model.to)
                    HStack {
                        Button("From here") { model.from = model.rig?.focus; model.refresh() }
                        Spacer()
                        Button { model.swap() } label: { Label("Swap", systemImage: "arrow.up.arrow.down") }
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
                Section {
                    Picker("Travel", selection: $model.mode) {
                        ForEach(DirectionsModel.Mode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        ForEach(DirectionsModel.Mode.allCases) { m in
                            Text(model.times[m] ?? "").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                    Picker("Spacetime bubble", selection: $model.speed) {
                        ForEach(DirectionsModel.speeds, id: \.1) { s in Text(s.0).tag(s.1) }
                    }
                }
                Section {
                    DisclosureGroup {
                        Text("Some rabbitholes open only while their galaxy is above your horizon, and some once you have been there. Your location and the places you have visited stay on this device.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(model.locating ? "Finding you…" : "Use my location") { model.locate() }
                            .disabled(model.locating)
                        HStack {
                            TextField("Latitude", text: $latText).onSubmit(applyWhere)
                            TextField("Longitude", text: $lonText).onSubmit(applyWhere)
                        }
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    } label: {
                        Text("\(model.openGates.count) of \(model.liveGateCount) rabbitholes open to you now: \(model.openGates.map(\.name).joined(separator: ", ")).")
                            .font(.caption)
                    }
                }
                if let route = model.route {
                    if !route.notes.isEmpty {
                        Section {
                            ForEach(route.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    Section("Steps") {
                        ForEach(Array(route.steps.enumerated()), id: \.element.id) { i, s in
                            Button { model.stop(); model.show(i) } label: { stepRow(i, s) }
                                .buttonStyle(.plain)
                                .listRowBackground(model.current == i ? Color.accentColor.opacity(0.18) : nil)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            Button { model.playing ? model.stop() : model.start() } label: {
                Text(model.playing ? "Stop" : "Start").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.route == nil)
            .padding()
        }
        .onAppear {
                if model.from == nil { model.from = model.rig?.focus }
                latText = model.lat.map { String($0) } ?? ""
                lonText = model.lon.map { String($0) } ?? ""
                model.refresh()
            }
            .onChange(of: model.lat) { latText = model.lat.map { String($0) } ?? "" }
            .onChange(of: model.lon) { lonText = model.lon.map { String($0) } ?? "" }
    }

    private func applyWhere() {
        let la = Double(latText), lo = Double(lonText)
        if let la, let lo, abs(la) <= 90, abs(lo) <= 180 { model.lat = la; model.lon = lo }
        else if latText.isEmpty && lonText.isEmpty { model.lat = nil; model.lon = nil }
        model.refresh()
    }

    private func placePicker(_ title: String, selection: Binding<Flight.Place?>) -> some View {
        Picker(title, selection: Binding(get: { selection.wrappedValue }, set: { selection.wrappedValue = $0; model.stop(); model.refresh() })) {
            Text("Choose a place").tag(Flight.Place?.none)
            ForEach(model.places) { p in Text(p.name).tag(Flight.Place?.some(p)) }
        }
    }

    private func stepRow(_ i: Int, _ s: Directions.Step) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(i + 1)")
                .font(.caption2.weight(.bold)).foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(Circle().fill(s.jump ? Color(red: 1, green: 0.48, blue: 0.85) : Color(red: 0.49, green: 0.84, blue: 1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.text).font(.subheadline.weight(.semibold))
                Text(model.when(s, index: i)).font(.caption).foregroundStyle(.tint)
                Text(s.detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
