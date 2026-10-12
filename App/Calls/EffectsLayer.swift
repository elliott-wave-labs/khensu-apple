// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// One effect on screen. Positions are normalised to the video, origin at top left.
struct ActiveEffect: Identifiable, Sendable {
    let id = UUID()
    let kind: CallEffect
    let center: CGPoint
    let start: Date
    let seed: UInt64
    /// Who set it off, shown under the heart.
    let from: String?

    var duration: Double { kind == .heart ? 3.0 : 2.4 }
}

/// ñü.aura colours, the same as the particle numbers on khensu.nu/creators.
enum Aura {
    static let glow: [Color] = [Color(hex: 0x22F59A), Color(hex: 0x1E8FFF), Color(hex: 0x8B5CFF)]
    static let core: [Color] = [Color(hex: 0x6DFFBF), Color(hex: 0x4FB0FF), Color(hex: 0xA98BFF)]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Draws every active effect with additive glow particles.
struct EffectsLayer: View {
    let effects: [ActiveEffect]

    var body: some View {
        TimelineView(.animation(paused: effects.isEmpty)) { timeline in
            Canvas { ctx, size in
                ctx.blendMode = .plusLighter
                let now = timeline.date
                for e in effects {
                    let t = now.timeIntervalSince(e.start)
                    guard t >= 0, t < e.duration else { continue }
                    let c = CGPoint(x: e.center.x * size.width, y: e.center.y * size.height)
                    switch e.kind {
                    case .heart: Self.heart(ctx, c, t, e.seed, size, now)
                    case .spark: Self.spark(ctx, c, t, e.seed, size, now)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Heart

    private static let heartCount = 520

    /// Dissolves in backwards (0–0.9 s), holds and beats (0.9–1.9 s), explodes (1.9–3.0 s).
    static func heart(_ ctx: GraphicsContext, _ c: CGPoint, _ t: Double, _ seed: UInt64, _ size: CGSize, _ now: Date) {
        var rng = SplitMix(seed)
        let scale = min(size.width, size.height) * 0.017
        let clock = now.timeIntervalSinceReferenceDate
        for i in 0..<heartCount {
            let a = rng.unit() * 2 * .pi
            let fill = i % 5 < 3 ? 0.88 + rng.unit() * 0.12 : rng.unit().squareRoot()
            let hx = 16 * pow(sin(a), 3)
            let hy = -(13 * cos(a) - 5 * cos(2 * a) - 2 * cos(3 * a) - cos(4 * a))
            let target = CGPoint(x: c.x + hx * fill * scale, y: c.y + hy * fill * scale)
            let dir = rng.unit() * 2 * .pi
            let far = (0.45 + rng.unit() * 0.6) * max(size.width, size.height) * 0.6
            let hue = rng.unit()
            let r0 = 0.9 + rng.unit() * 1.4
            let blastDir = atan2(target.y - c.y, target.x - c.x) + (rng.unit() - 0.5) * 0.9
            let blastDist = (0.35 + rng.unit() * 0.9) * max(size.width, size.height) * 0.55

            var p: CGPoint
            var alpha: Double
            if t < 0.9 {
                let k = ease(t / 0.9)
                let swirl = (1 - k) * 1.6
                let ox = cos(dir + swirl) * far * (1 - k)
                let oy = sin(dir + swirl) * far * (1 - k)
                p = CGPoint(x: target.x + ox, y: target.y + oy)
                alpha = 0.15 + 0.85 * k
            } else if t < 1.9 {
                let beat = 1 + 0.07 * pow(max(0, sin((t - 0.9) * .pi * 2.4)), 6)
                p = CGPoint(x: c.x + (target.x - c.x) * beat, y: c.y + (target.y - c.y) * beat)
                alpha = 1
            } else {
                let k = (t - 1.9) / 1.1
                let e = 1 - pow(1 - k, 3)
                p = CGPoint(x: target.x + cos(blastDir) * blastDist * e,
                            y: target.y + sin(blastDir) * blastDist * e + 120 * k * k)
                alpha = max(0, 1 - k * k)
            }
            p.x += sin(clock * 1.3 + hue * 40) * 0.6
            p.y += cos(clock * 1.1 + hue * 30) * 0.6
            dot(ctx, p, r0, hue, clock, alpha)
        }
    }

    // MARK: Spark

    /// Aura fireworks: two shells, each a ring of sparks under light gravity.
    static func spark(_ ctx: GraphicsContext, _ c: CGPoint, _ t: Double, _ seed: UInt64, _ size: CGSize, _ now: Date) {
        var rng = SplitMix(seed)
        let clock = now.timeIntervalSinceReferenceDate
        let reach = min(size.width, size.height) * 0.32
        for shell in 0..<2 {
            let delay = Double(shell) * 0.45
            let st = t - delay
            let origin = CGPoint(x: c.x + (shell == 0 ? -1 : 1) * reach * 0.35, y: c.y - reach * (0.25 + 0.2 * Double(shell)))
            for _ in 0..<170 {
                let a = rng.unit() * 2 * .pi
                let v = (0.55 + rng.unit() * 0.45) * reach
                let hue = rng.unit()
                let r0 = 0.8 + rng.unit() * 1.2
                guard st > 0 else { continue }
                let k = min(1, st / 1.6)
                let e = 1 - pow(1 - k, 3)
                for trail in 0..<3 {
                    let tk = max(0, e - Double(trail) * 0.035)
                    let p = CGPoint(x: origin.x + cos(a) * v * tk, y: origin.y + sin(a) * v * tk + 90 * k * k)
                    dot(ctx, p, r0 * (1 - Double(trail) * 0.25), hue, clock, max(0, 1 - k) * (1 - Double(trail) * 0.3))
                }
            }
        }
    }

    // MARK: Drawing

    static func dot(_ ctx: GraphicsContext, _ p: CGPoint, _ r0: Double, _ hue: Double, _ clock: Double, _ alpha: Double) {
        let pulse = 0.5 + 0.5 * sin(clock * 2.6 + hue * 60)
        let r = r0 * (0.75 + pulse * 0.6)
        let i = Int(hue * 3 + clock * 0.12) % 3
        var g = ctx
        g.opacity = (0.18 + pulse * 0.22) * alpha
        g.fill(Path(ellipseIn: CGRect(x: p.x - r * 3.2, y: p.y - r * 3.2, width: r * 6.4, height: r * 6.4)), with: .color(Aura.glow[i]))
        g.opacity = (0.75 + pulse * 0.25) * alpha
        g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(Aura.core[i]))
    }

    static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}

/// Deterministic random numbers, so every device draws the same particles
/// for the same effect without sending them.
struct SplitMix {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
