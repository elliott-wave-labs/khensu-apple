// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes — RealityKit scene: instanced spectral stars, M33 disc, floating origin.
// Spec §§2, 7–8. RealityView on iOS/iPadOS/macOS 26; AR via world tracking where available.

import SwiftUI
import RealityKit
import simd

#if os(iOS)
import ARKit
#endif

/// A galaxy you can fly through and put on your table. Stars are instanced
/// sphere sprites whose colour comes from the 19-channel cube each frame —
/// change the observer and the same scene re-renders in UV, gamma or mantis.
public struct UniversesRealityView: View {
    public var stars: [StarBody]
    public var observer: Observer
    public var cosmicTime: CosmicTime
    public var atmosphere: TwinklePhysics.Atmosphere
    public var arEnabled: Bool
    @State private var root = Entity()
    @State private var starEntities: [Entity] = []
    @State private var startDate = Date()

    public init(stars: [StarBody], observer: Observer, cosmicTime: CosmicTime,
                atmosphere: TwinklePhysics.Atmosphere, arEnabled: Bool) {
        self.stars = stars; self.observer = observer; self.cosmicTime = cosmicTime
        self.atmosphere = atmosphere; self.arEnabled = arEnabled
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            RealityView { content in
                rebuild(content: content, at: timeline.date)
            } update: { content in
                update(content: content, at: timeline.date)
            }
            .ignoresSafeArea()
        }
    }

    @State private var needsRebuild = true

    private func rebuild(content: RealityViewCameraContent, at date: Date) {
        // Galaxy disc underlay: a thin disc entity standing in for the Hubble-tile layer.
        // Tiles stream over this disc in the hosted build; geometry keeps the map honest at far zoom.
        let discMesh = MeshResource.generateBox(width: 2, height: 0.02, depth: 2)
        var discMat = PhysicallyBasedMaterial()
        discMat.baseColor = .init(tint: .init(red: 0.35, green: 0.45, blue: 0.75, alpha: 0.55))
        discMat.emissiveColor = .init(color: .init(red: 0.10, green: 0.15, blue: 0.35, alpha: 1))
        discMat.emissiveIntensity = 0.6
        let disc = ModelEntity(mesh: discMesh, materials: [discMat])
        disc.name = "m33-disc"
        root.addChild(disc)

        // Star instances: one low-poly sphere mesh, per-instance material tint from the cube.
        let sphere = MeshResource.generateSphere(radius: 0.006)
        for star in stars.prefix(1200) {
            var mat = UnlitMaterial()
            let rgb = displayRGB(for: star, at: date)
            mat.color = .init(tint: .init(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1))
            let e = ModelEntity(mesh: sphere, materials: [mat])
            e.name = star.id
            e.position = scenePosition(for: star)
            let s = scaleFor(magnitude: star.apparentMagnitude)
            e.scale = SIMD3<Float>(repeating: s)
            root.addChild(e)
            starEntities.append(e)
        }
        content.add(root)
        needsRebuild = false
    }

    private func update(content: RealityViewCameraContent, at date: Date) {
        // Floating origin: keep the galaxy centred; camera orbits (RealityView handles the rig).
        let elapsed = date.timeIntervalSince(startDate)
        // Slow galactic rotation (M33 rotates; period ~ compressed for legibility, labelled in UI).
        root.orientation = simd_quatf(angle: Float(elapsed * 0.01), axis: SIMD3<Float>(0, 1, 0))
        for (i, entity) in starEntities.enumerated() where i < stars.count {
            let star = stars[i]
            let rgb = displayRGB(for: star, at: date)
            if var mat = (entity as? ModelEntity)?.model?.materials.first as? UnlitMaterial {
                mat.color = .init(tint: .init(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1))
                (entity as? ModelEntity)?.model?.materials = [mat]
            }
        }
    }

    private func displayRGB(for star: StarBody, at date: Date) -> SIMD3<Float> {
        let days = date.timeIntervalSince(startDate) / 86_400 * 365 // time-lapse: 1 s ≈ 1 yr of variable phase
        let state = TwinklePhysics.intrinsicState(of: star, atDays: days)
        var cube = SpectralCube.blackbody(temperatureK: state.temperatureK, flux: Float(min(state.flux, 3)))
        cube.channels[16] = Float(min(state.flux, 3))
        let scint = TwinklePhysics.scintillationMultiplier(
            star: star, atSeconds: date.timeIntervalSince(startDate), wavelengthNm: 550,
            zenithAngleRad: 0.6, angularDiameterArcsec: 0, atmosphere: atmosphere)
        var rgb = SpectralMapper.rgb(cube, observer: observer)
        rgb *= Float(scint)
        return SIMD3<Float>(min(rgb.x, 1), min(rgb.y, 1), min(rgb.z, 1))
    }

    /// Disc-plane ly offsets → scene units: 30,000 ly ≈ radius 1.
    private func scenePosition(for star: StarBody) -> SIMD3<Float> {
        let ly = star.positionPc / 0.3066
        return SIMD3<Float>(Float(ly.x / 30_000), Float(ly.z / 30_000) * 0.05, Float(ly.y / 30_000))
    }

    private func scaleFor(magnitude: Double) -> Float {
        Float(max(0.4, 2.2 - (magnitude - 12) * 0.12))
    }
}

// MARK: - AR session helper (§7)

#if os(iOS)
/// Sky/tabletop AR configuration for the hosted surface. Frames never leave the device.
public enum UniversesAR {
    public static var isWorldTrackingSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    public static func configuration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        return config
    }
}
#endif
