// SPDX-License-Identifier: AGPL-3.0-only
// nu.universes — RealityKit flight through one continuous map in parsecs: planets on today's
// orbits, 42,246 catalogue stars, the Milky Way model, 869 nearby galaxies with measured
// distances, 43,415 survey galaxies, and M33's Hubble mosaic at its real place. Spec §§2, 7–8.

import SwiftUI
import RealityKit
import Metal
import simd

#if os(iOS)
import ARKit
#endif

/// Orbit camera over the map, Google Earth style: a target, a distance, and a heading.
/// Distances span 10⁻⁹ to 10⁹ pc, so everything is Double until it reaches the GPU.
@MainActor @Observable
final class FlightRig {
    var target = SIMD3<Double>(0, 0, 0)
    var distance = 2.5 * Flight.au
    var yaw = 0.9
    var pitch = 0.35
    var focus: Flight.Place?
    var readout = ""
    var labels: [(place: Flight.Place, point: CGPoint)] = []
    var viewport = CGSize(width: 390, height: 844)
    let fovY = 55.0 * Double.pi / 180
    /// Called when a flight or a rabbithole jump reaches its place.
    var onArrive: ((Flight.Place) -> Void)?
    /// Route legs to draw over the map, and their screen polylines, refreshed with the labels.
    var route: [Directions.Leg] = []
    var routeLines: [(points: [CGPoint], jump: Bool)] = []
    /// Bumped on each rabbithole jump, for the flash.
    var jumps = 0

    private var flight: (from: SIMD3<Double>, to: SIMD3<Double>, d0: Double, d1: Double, hop: Double, t: Double, dur: Double,
                         yaw: (Double, Double), pitch: (Double, Double))?

    var direction: SIMD3<Double> {
        SIMD3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
    }
    var eye: SIMD3<Double> { target + direction * distance }

    func fly(to p: Flight.Place) {
        focus = p
        let gap = simd_distance(target, p.position)
        let hop = max(0, log(max(gap * 0.8, 1e-12)) - (log(distance) + log(p.view)) / 2)
        let (y1, p1) = heading(for: p)
        flight = (target, p.position, distance, p.view, hop, 0, 1.6 + min(3, hop * 0.25), (yaw, y1), (pitch, p1))
    }

    func jump(to p: Flight.Place) {
        focus = p; flight = nil; target = p.position; distance = p.view
        (yaw, pitch) = heading(for: p)
        jumps += 1
        onArrive?(p)
    }

    /// The place's best viewing direction as yaw and pitch, taking the short way round in yaw.
    private func heading(for p: Flight.Place) -> (Double, Double) {
        guard let f = p.facing else { return (yaw, pitch) }
        var y = atan2(f.y, f.x)
        while y - yaw > .pi { y -= 2 * .pi }
        while y - yaw < -.pi { y += 2 * .pi }
        return (y, min(max(asin(f.z), -1.5), 1.5))
    }

    func orbit(dx: Double, dy: Double) {
        flight = nil
        yaw -= dx * 0.005
        pitch = min(max(pitch + dy * 0.005, -1.5), 1.5)
    }

    func zoom(by factor: Double) {
        flight = nil
        distance = min(max(distance / factor, 2e-9), 4e9)
    }

    func step(dt: Double) {
        guard var f = flight else { return }
        f.t = min(1, f.t + dt / f.dur)
        let s = f.t * f.t * (3 - 2 * f.t)
        let logD = log(f.d0) + (log(f.d1) - log(f.d0)) * s + f.hop * sin(.pi * s)
        let u0 = f.hop > 0 ? min(1, max(0, (s - 0.15) / 0.7)) : s
        let u = u0 * u0 * (3 - 2 * u0)
        target = f.from + (f.to - f.from) * u
        distance = exp(logD)
        yaw = f.yaw.0 + (f.yaw.1 - f.yaw.0) * s
        pitch = f.pitch.0 + (f.pitch.1 - f.pitch.0) * s
        flight = f.t >= 1 ? nil : f
        if f.t >= 1, let p = focus { onArrive?(p) }
    }

    /// Screen point for a world position, or nil when behind the camera (or well off screen, with `clip`).
    func project(_ p: SIMD3<Double>, clip: Bool = true) -> CGPoint? {
        let fwd = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(fwd, SIMD3(0, 0, 1)))
        let up = simd_cross(right, fwd)
        let v = p - eye
        let z = simd_dot(v, fwd)
        guard z > 0 else { return nil }
        let f = Double(viewport.height) / 2 / tan(fovY / 2)
        let x = Double(viewport.width) / 2 + simd_dot(v, right) / z * f
        let y = Double(viewport.height) / 2 - simd_dot(v, up) / z * f
        guard !clip || (x > -40 && y > -40 && x < Double(viewport.width) + 40 && y < Double(viewport.height) + 40) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Each leg as screen polylines, sampled densely near both ends so short and huge legs both draw.
    func projectRoute() {
        routeLines = route.flatMap { leg -> [(points: [CGPoint], jump: Bool)] in
            var runs: [[CGPoint]] = [[]]
            let d = simd_distance(leg.from, leg.to)
            guard d > 0 else { return [] }
            var ss = Set([0.0, d])
            for k in 0...80 {
                let s = 1e-6 * pow(d / 1e-6, Double(k) / 80)
                if s < d { ss.insert(s); ss.insert(d - s) }
            }
            for s in ss.sorted() {
                if let pt = project(leg.from + (leg.to - leg.from) * (s / d), clip: false),
                   abs(pt.x) < 1e5, abs(pt.y) < 1e5 { runs[runs.count - 1].append(pt) }
                else if !runs[runs.count - 1].isEmpty { runs.append([]) }
            }
            return runs.filter { $0.count > 1 }.map { ($0, leg.jump) }
        }
    }
}

/// Builds the sprite layers once and updates camera, exposure and labels every frame.
@MainActor
final class FlightScene {
    let catalog: Flight.Catalog
    let rig: FlightRig
    let world = Entity()
    let camera = PerspectiveCamera()
    #if os(iOS)
    let tableAnchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: [0.2, 0.2]))
    #endif
    private var layers: [(entity: ModelEntity, material: CustomMaterial, layer: Flight.Layer)] = []
    private var subscription: EventSubscription?
    private var elapsed = 0.0
    private var sinceLabels = 0.0
    var atmosphere = TwinklePhysics.Atmosphere.space
    var arEnabled: Bool?

    init(catalog: Flight.Catalog, rig: FlightRig) { self.catalog = catalog; self.rig = rig }

    func build(content: RealityViewCameraContent) async {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary() else {
            NSLog("nu.universes: no Metal library")
            return
        }
        let surface = CustomMaterial.SurfaceShader(named: "nuFlightSurface", in: library)
        let geometry = CustomMaterial.GeometryModifier(named: "nuFlightGeometry", in: library)

        var all = catalog.layers
        all.append(Flight.Layer(name: "orbits", points: catalog.orbits.flatMap { o in
            o.points.map { Flight.Point(position: $0, absMag: 31, diameter: 0, tint: o.tint * 0.6) }
        }, limit: 6, exposure: 0))

        for layer in all where !layer.points.isEmpty {
            let mesh: MeshResource
            var material: CustomMaterial
            do {
                mesh = try Self.spriteMesh(layer.points)
                material = try CustomMaterial(surfaceShader: surface, geometryModifier: geometry, lightingModel: .unlit)
            } catch {
                NSLog("nu.universes: layer %@ unavailable: %@", layer.name, "\(error)")
                continue
            }
            material.blending = .transparent(opacity: .init(scale: 1))
            material.faceCulling = .none
            material.writesDepth = false
            let e = ModelEntity(mesh: mesh, materials: [material])
            e.name = layer.name
            world.addChild(e)
            layers.append((e, material, layer))
        }

        if let m33 = catalog.m33,
           let url = Bundle.main.url(forResource: M33.mosaicResource, withExtension: "jpg"),
           let tex = try? await TextureResource(contentsOf: url),
           var mat = try? CustomMaterial(surfaceShader: .init(named: "nuMosaicSurface", in: library), lightingModel: .unlit) {
            mat.emissiveColor = .init(color: .white, texture: .init(tex))
            mat.blending = .transparent(opacity: .init(scale: 0.95))
            mat.writesDepth = false
            mat.faceCulling = .none
            let width = Float(14_000 * Flight.lightYear)
            let plane = ModelEntity(mesh: .generatePlane(width: width, height: width / M33.mosaicAspect), materials: [mat])
            let (major, minor, normal) = Flight.discBasis(m33, pa: 23, inc: 54)
            plane.transform = Transform(matrix: simd_float4x4(columns: (
                SIMD4(SIMD3<Float>(major), 0), SIMD4(SIMD3<Float>(minor), 0), SIMD4(SIMD3<Float>(normal), 0), SIMD4(SIMD3<Float>(m33), 1))))
            world.addChild(plane)
        }

        camera.camera.fieldOfViewInDegrees = Float(rig.fovY * 180 / .pi)
        world.addChild(camera)
        content.add(world)
        #if os(iOS)
        content.add(tableAnchor)
        #endif
        tick(dt: 0)
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.tick(dt: event.deltaTime) }
        }
    }

    /// Four corners per source; the geometry modifier turns each into a camera-facing sprite.
    static func spriteMesh(_ points: [Flight.Point]) throws -> MeshResource {
        let n = points.count, stride = 13
        var desc = LowLevelMesh.Descriptor()
        desc.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: 0),
            .init(semantic: .uv0, format: .float2, offset: 12),
            .init(semantic: .uv2, format: .float4, offset: 20),
            .init(semantic: .uv3, format: .float4, offset: 36),
        ]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: stride * 4)]
        desc.vertexCapacity = n * 4
        desc.indexCapacity = n * 6
        desc.indexType = .uint32
        let mesh = try LowLevelMesh(descriptor: desc)
        let corners: [SIMD2<Float>] = [[-1, -1], [1, -1], [1, 1], [-1, 1]]
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let f = raw.bindMemory(to: Float.self)
            var k = 0
            for p in points {
                for c in corners {
                    f[k] = p.position.x; f[k + 1] = p.position.y; f[k + 2] = p.position.z
                    f[k + 3] = c.x; f[k + 4] = c.y
                    f[k + 5] = p.absMag; f[k + 6] = p.diameter; f[k + 7] = p.gain; f[k + 8] = p.seed
                    f[k + 9] = p.tint.x; f[k + 10] = p.tint.y; f[k + 11] = p.tint.z; f[k + 12] = 1
                    k += stride
                }
            }
        }
        mesh.withUnsafeMutableIndices { raw in
            let idx = raw.bindMemory(to: UInt32.self)
            for i in 0..<n {
                let b = UInt32(i * 4)
                idx.baseAddress!.advanced(by: i * 6).update(from: [b, b + 1, b + 2, b, b + 2, b + 3], count: 6)
            }
        }
        let big = Float(1e10)
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: n * 6, topology: .triangle,
                                                 bounds: BoundingBox(min: SIMD3(repeating: -big), max: SIMD3(repeating: big)))])
        return try MeshResource(from: mesh)
    }

    private func tick(dt: Double) {
        elapsed += dt
        rig.step(dt: dt)
        let inAR = arEnabled == true
        let dist = rig.distance

        if inAR {
            // The current view, 30 cm across on the table.
            let s = Float(0.3 / dist)
            world.scale = SIMD3(repeating: s)
            world.position = -SIMD3<Float>(rig.target) * s
        } else {
            world.scale = .one
            world.position = .zero
            camera.camera.near = Float(max(1e-10, dist * 1e-3))
            camera.camera.far = Float(max(1e10, dist * 1e3))
            camera.look(at: SIMD3<Float>(rig.target), from: SIMD3<Float>(rig.eye), upVector: [0, 0, 1], relativeTo: world)
        }

        let height = max(Double(rig.viewport.height), 1)
        let focal = Float(height * displayScale / (2 * tan(rig.fovY / 2)))
        let zoom = Float(log10(max(1, dist / 1e-3)))
        let fromEarth = simd_length(rig.eye) < 0.001
        let sigma = atmosphere.enabled && fromEarth
            ? Float(sqrt(TwinklePhysics.scintillationIndex(wavelengthNm: 550, zenithAngleRad: 0.6, atmosphere: atmosphere))) : 0
        let outside = Float(smoothstep(1500, 12000, simd_length(rig.eye)))
        for i in layers.indices {
            let l = layers[i].layer
            var gain: Float = 1
            if let inside = l.gainInside { gain = 0.5 * (inside + (1 - inside) * outside) }
            let limit = l.limit + zoom * l.exposure + 2.5 * log10(gain)
            layers[i].material.custom.value = SIMD4(focal, limit, l.name == "stars" ? sigma : 0, Float(elapsed.truncatingRemainder(dividingBy: 1000)))
            layers[i].entity.model?.materials = [layers[i].material]
        }

        sinceLabels += dt
        if sinceLabels > 1.0 / 20 {
            sinceLabels = 0
            rig.readout = "\(Flight.distanceText(simd_length(rig.eye))) from the Sun · view \(Flight.distanceText(dist)) wide"
            if inAR { rig.routeLines = [] } else { rig.projectRoute() }
            rig.labels = inAR ? [] : catalog.places.compactMap { p in
                let d = simd_distance(rig.eye, p.position)
                guard p.showWithin > 0, d < p.showWithin, d > p.view * 0.02, dist > p.minView, let pt = rig.project(p.position) else { return nil }
                return (p, pt)
            }
        }
    }

    private var displayScale: Double {
        #if os(iOS)
        Double(UIScreen.main.scale)
        #else
        Double(NSScreen.main?.backingScaleFactor ?? 2)
        #endif
    }

    private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Virtual camera over the map, or the current view 30 cm across on a real table.
    func apply(ar: Bool, content: inout RealityViewCameraContent) {
        guard arEnabled != ar else { return }
        arEnabled = ar
        world.removeFromParent()
        #if os(iOS)
        if ar {
            content.camera = .spatialTracking
            camera.isEnabled = false
            tableAnchor.addChild(world)
            return
        }
        content.camera = .virtual
        #endif
        camera.isEnabled = true
        content.add(world)
    }
}

/// The flight surface: RealityKit view, map gestures, and tappable labels.
struct UniversesRealityView: View {
    let catalog: Flight.Catalog
    var rig: FlightRig
    var atmosphere: TwinklePhysics.Atmosphere
    var arEnabled: Bool

    @State private var scene: FlightScene?
    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnify: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RealityView { content in
                    let s = FlightScene(catalog: catalog, rig: rig)
                    scene = s
                    await s.build(content: content)
                } update: { content in
                    guard let scene else { return }
                    scene.atmosphere = atmosphere
                    scene.apply(ar: arEnabled, content: &content)
                }
                .gesture(gestures)
                .onTapGesture(count: 2) { rig.zoom(by: 2) }

                Canvas { ctx, _ in
                    for line in rig.routeLines {
                        var path = Path()
                        path.addLines(line.points)
                        ctx.stroke(path, with: .color(line.jump ? Color(red: 1, green: 0.48, blue: 0.85) : Color(red: 0.49, green: 0.84, blue: 1)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: line.jump ? [6, 5] : []))
                    }
                }
                .allowsHitTesting(false)
                JumpFlash(count: rig.jumps)

                ForEach(rig.labels, id: \.place.name) { item in
                    Button(item.place.name) { rig.fly(to: item.place) }
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.white)
                        .fixedSize()
                        .position(x: item.point.x + 40, y: item.point.y + 14)
                }
            }
            .onAppear { rig.viewport = geo.size }
            .onChange(of: geo.size) { _, s in rig.viewport = s }
        }
        .ignoresSafeArea()
    }

    private var gestures: some Gesture {
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { v in
                rig.orbit(dx: Double(v.translation.width - lastDrag.width), dy: Double(v.translation.height - lastDrag.height))
                lastDrag = v.translation
            }
            .onEnded { _ in lastDrag = .zero }
        let pinch = MagnifyGesture()
            .onChanged { v in
                rig.zoom(by: Double(v.magnification / lastMagnify))
                lastMagnify = v.magnification
            }
            .onEnded { _ in lastMagnify = 1 }
        return drag.simultaneously(with: pinch)
    }
}

/// The rabbithole flash: a pink burst that fades as the new place appears.
private struct JumpFlash: View {
    let count: Int
    @State private var on = false
    var body: some View {
        RadialGradient(colors: [Color(red: 1, green: 0.48, blue: 0.85).opacity(0.85), Color(red: 0.49, green: 0.84, blue: 1).opacity(0.25), .clear],
                       center: .center, startRadius: 0, endRadius: 600)
            .scaleEffect(on ? 1.6 : 0.4)
            .opacity(on ? 0 : 1)
            .allowsHitTesting(false)
            .opacity(count == 0 ? 0 : 1)
            .onChange(of: count) {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { on = false }
                Task { @MainActor in withAnimation(.easeOut(duration: 0.7)) { on = true } }
            }
            .onAppear { on = true }
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
