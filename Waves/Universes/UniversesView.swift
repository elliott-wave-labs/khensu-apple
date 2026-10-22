// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes (nu.u) — SwiftUI shell inside nu.waves. Spec: design/nu-universes.md.
// Google Earth grammar for the universe: fly to a place, drag to turn, pinch to zoom.

import SwiftUI

public struct UniversesView: View {
    @State private var catalog = Flight.load()
    @State private var rig = FlightRig()
    @State private var cosmicTime: CosmicTime = .today
    @State private var arEnabled = false
    @State private var atmosphereOn = false
    @State private var immersive = false
    @State private var deckOpen = true
    @State private var directions: DirectionsModel?
    @State private var showDirections = false

    private var atmosphere: TwinklePhysics.Atmosphere { atmosphereOn ? .earthDefault : .space }
    private let chips: [(String, String)] = [
        ("Earth", "Earth"), ("Solar System", "Sun"), ("Alpha Centauri", "Rigil Kentaurus"), ("Milky Way", "Milky Way"),
        ("LMC", "Large Magellanic Cloud"), ("Andromeda", "Andromeda Galaxy · M31"), ("M33", "Triangulum Galaxy · M33"),
        ("NGC 604", "NGC 604"), ("Cosmic web", "Cosmic web"),
    ]

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                UniversesRealityView(catalog: catalog, rig: rig, atmosphere: atmosphere, arEnabled: arEnabled)
                if immersive {
                    VStack {
                        HStack {
                            Spacer()
                            Button { setImmersive(false) } label: {
                                Label("Exit fullscreen", systemImage: "arrow.down.right.and.arrow.up.left")
                                    .labelStyle(.iconOnly).padding(6)
                            }
                            .buttonStyle(.glass)
                        }
                        Spacer()
                    }
                    .padding()
                } else {
                    VStack {
                        Spacer()
                        controlDeck
                    }
                }
            }
            .inspector(isPresented: $showDirections) {
                if let directions {
                    DirectionsView(model: directions) { showDirections = false }
                        .presentationDetents([.medium, .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 460)
                }
            }
            .onChange(of: showDirections) { _, on in if !on { directions?.clear() } else { directions?.refresh() } }
            .navigationTitle("nu.universes")
            .wavesNavChrome()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(immersive ? .hidden : .visible, for: .navigationBar, .tabBar)
            .statusBarHidden(immersive)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("nu.i.verse · part of nu.waves").font(.caption).foregroundStyle(.secondary)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        ForEach(catalog.places) { p in
                            Button(p.name) { rig.fly(to: p) }
                        }
                    } label: {
                        Label("Fly to", systemImage: "magnifyingglass")
                    }
                    Button { showDirections.toggle() } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
                    Button { setImmersive(true) } label: {
                        Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Button { arEnabled.toggle() } label: {
                        Label(arEnabled ? "Exit AR" : "View in AR", systemImage: arEnabled ? "xmark.viewfinder" : "arkit")
                    }
                }
            }
            .onAppear {
                if rig.focus == nil, let sun = catalog.places.first { rig.focus = sun }
                if directions == nil { directions = DirectionsModel(places: catalog.places, rig: rig) }
                if let name = UserDefaults.standard.string(forKey: "directions"),
                   let p = catalog.places.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    directions?.to = p
                    showDirections = true
                }
                if let name = UserDefaults.standard.string(forKey: "place"),
                   let p = catalog.places.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) { rig.jump(to: p) }
            }
        }
    }

    private func setImmersive(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { immersive = on }
    }

    private var controlDeck: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { deckOpen.toggle() }
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rig.focus?.name ?? "Sun").font(.headline)
                        Text(rig.focus?.kind ?? "").font(.caption2).foregroundStyle(.secondary)
                        if deckOpen, let note = rig.focus?.note {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(rig.readout).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: deckOpen ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(chips, id: \.0) { chip in
                        Button(chip.0) {
                            if let p = catalog.places.first(where: { $0.name == chip.1 }) { rig.fly(to: p) }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }

            if deckOpen { deckControls }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    @ViewBuilder private var deckControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Big Bang").font(.caption2)
                Spacer()
                Text(cosmicTime.label).font(.caption2).foregroundStyle(cosmicTime.isPrediction ? .orange : .secondary)
                Spacer()
                Text("+10 Gyr").font(.caption2)
            }
            Slider(value: Binding(
                get: { cosmicTime.gyrAfterBigBang },
                set: { cosmicTime = CosmicTime(gyrAfterBigBang: $0) }),
                in: 0...23.8)
            HStack {
                Toggle("Earth atmosphere (real scintillation)", isOn: $atmosphereOn)
                    .font(.caption2)
                Spacer()
                Text(atmosphereOn ? "From Earth, stars twinkle" : "In space, stars do not twinkle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
