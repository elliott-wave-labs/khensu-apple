// SPDX-License-Identifier: AGPL-3.0-only

import simd
import SwiftUI

/// A slowly turning sphere of connected dots, the recurring motif for the lock
/// screen, onboarding and empty states. Static when Reduce Motion is on.
struct DotNetwork: View {
    let count: Int
    let linkDistance: Double
    let speed: Double
    let opacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let points: [SIMD3<Double>]

    init(count: Int = 64, linkDistance: Double = 0.62, speed: Double = 0.05, opacity: Double = 1) {
        self.count = count
        self.linkDistance = linkDistance
        self.speed = speed
        self.opacity = opacity
        // Fibonacci sphere: even spread, deterministic.
        let golden = Double.pi * (3 - 5.0.squareRoot())
        points = (0..<count).map { i in
            let y = 1 - (Double(i) / Double(count - 1)) * 2
            let radius = (1 - y * y).squareRoot()
            let theta = golden * Double(i)
            return SIMD3(cos(theta) * radius, y, sin(theta) * radius)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            Canvas { gc, size in
                let t = reduceMotion ? 0.6 : context.date.timeIntervalSinceReferenceDate * speed
                draw(in: &gc, size: size, angle: t)
            }
        }
        .opacity(opacity)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func draw(in gc: inout GraphicsContext, size: CGSize, angle: Double) {
        let r = min(size.width, size.height) * 0.46
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let tilt = 0.35
        let projected: [(CGPoint, Double)] = points.map { p in
            // Rotate about Y, then tilt about X.
            let x = p.x * cos(angle) + p.z * sin(angle)
            let z0 = -p.x * sin(angle) + p.z * cos(angle)
            let y = p.y * cos(tilt) - z0 * sin(tilt)
            let z = p.y * sin(tilt) + z0 * cos(tilt)
            return (CGPoint(x: center.x + x * r, y: center.y + y * r), (z + 1) / 2)
        }
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let d = simd_distance(points[i], points[j])
                guard d < linkDistance else { continue }
                let depth = (projected[i].1 + projected[j].1) / 2
                var path = Path()
                path.move(to: projected[i].0)
                path.addLine(to: projected[j].0)
                gc.stroke(path, with: .color(.white.opacity(0.05 + 0.18 * depth * (1 - d / linkDistance))), lineWidth: 0.6)
            }
        }
        for (p, depth) in projected {
            let s = 1.2 + 2.2 * depth
            gc.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                    with: .color(.white.opacity(0.2 + 0.7 * depth)))
        }
    }
}

#Preview {
    DotNetwork().frame(width: 320, height: 320).background(.black)
}
