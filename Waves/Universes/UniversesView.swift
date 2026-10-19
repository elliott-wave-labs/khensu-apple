// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes (nu.u) — SwiftUI shell inside nu.waves. Spec: design/nu-universes.md.
// Google Maps grammar for M33: pinch to descend, wavelength = pitch for light, cosmic timeline.

import SwiftUI

public struct UniversesView: View {
    @State private var scale: UniverseScale = .m33DeepMap
    @State private var band: SpectrumBand = .visible
    @State private var cosmicTime: CosmicTime = .today
    @State private var arEnabled = false
    @State private var atmosphereOn = false
    @State private var archiveEpoch: String?
    @State private var selectedLandmark: M33.Landmark?

    private var observer: Observer { Observer.from(band: band) }
    private var atmosphere: TwinklePhysics.Atmosphere { atmosphereOn ? .earthDefault : .space }

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                UniversesRealityView(
                    stars: M33.demoStars(), observer: observer, cosmicTime: cosmicTime,
                    atmosphere: atmosphere, arEnabled: arEnabled)
                VStack {
                    Spacer()
                    controlDeck
                }
            }
            .navigationTitle("nu.universes")
            .wavesNavChrome()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("nu.u · part of nu.waves").font(.caption).foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { arEnabled.toggle() } label: {
                        Label(arEnabled ? "Exit AR" : "View in AR", systemImage: arEnabled ? "xmark.viewfinder" : "arkit")
                    }
                }
            }
            .task {
                archiveEpoch = await M33DataService().fetchLatestEpoch()
            }
            .sheet(item: $selectedLandmark) { landmark in landmarkSheet(landmark) }
        }
    }

    private var controlDeck: some View {
        VStack(spacing: 10) {
            // Map header — like Google Maps: place name, scale, data epoch.
            VStack(alignment: .leading, spacing: 2) {
                Text("\(M33.name) · \(M33.messier)").font(.headline)
                Text("2.73 Mly away · you see it as it was 2.73 Myr ago · \(archiveEpoch ?? "cached map")")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("54 Hubble pointings · 665 Mpx mosaic · 25M resolved stars · \(M33.credits)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Scale picker (map zoom grammar).
            Picker("Scale", selection: $scale) {
                ForEach(UniverseScale.allCases, id: \.self) { s in Text(s.title).tag(s) }
            }
            .pickerStyle(.segmented)

            // Landmarks — the "pins" on the galaxy map.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(M33.landmarks) { lm in
                        Button(lm.name) { selectedLandmark = lm }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }

            // Wavelength — music is only the audible band. Log slider + detents.
            VStack(alignment: .leading, spacing: 4) {
                Text("Wavelength — music is only the audible band").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(SpectrumBand.allCases) { b in
                            Button {
                                band = b
                            } label: {
                                Text(b.title)
                                    .font(.caption2)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(band == b ? Color.accentColor : Color.white.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                            .foregroundStyle(.white)
                        }
                    }
                }
                if band == .mantis {
                    Text("Mantis · 19 channels (12 spectral + polarisation). False colour — mapped for your eyes. Things you call one colour separate here.")
                        .font(.caption2).foregroundStyle(.orange)
                } else if band == .audible {
                    Text("Sonified through nu.waves — brightness is loudness, polarisation is position in the spacetime bubble.")
                        .font(.caption2).foregroundStyle(.orange)
                } else if band != .visible {
                    Text("\(band.title) · false colour — mapped for your eyes.").font(.caption2).foregroundStyle(.orange)
                }
            }

            // Cosmic timeline — Big Bang → today → predicted.
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
                    Text(atmosphereOn ? "Stars twinkle: Earth's air" : "In space, stars do not twinkle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private func landmarkSheet(_ landmark: M33.Landmark) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(landmark.name).font(.title3.bold())
            Text(landmark.detail)
            Text("Size ~\(Int(landmark.sizeLy)) ly · tap a wavelength above to see it change.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .presentationDetents([.fraction(0.35)])
    }
}
