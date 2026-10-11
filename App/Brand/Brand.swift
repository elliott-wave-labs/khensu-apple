// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Monochrome palette (PLAN.md, App design): true black and graphite surfaces,
/// silver for your bubbles, starlight white for actions, red only for
/// destructive actions and ending calls.
enum Palette {
    static let starlight = Color(red: 0.96, green: 0.965, blue: 0.98)
    static let silver = Color(red: 0.78, green: 0.80, blue: 0.84)
    static let graphite = Color(white: 0.11)
    static let graphiteRaised = Color(white: 0.16)
    static let dim = Color(white: 0.55)
}

/// The crescent mark: a ring plus an inner arc of a slightly larger circle,
/// meeting the ring at top and bottom centre (same geometry as the app icon).
struct CrescentMark: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r2 = r * 1.16
        let dx = (r2 * r2 - r * r).squareRoot()
        let half = asin(r / r2)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        p.addArc(center: CGPoint(x: c.x + dx, y: c.y), radius: r2,
                 startAngle: .radians(.pi - half), endAngle: .radians(.pi + half), clockwise: false)
        return p
    }
}

struct CrescentLogo: View {
    var size: CGFloat = 72
    var body: some View {
        CrescentMark()
            .stroke(Palette.starlight, style: StrokeStyle(lineWidth: max(1.5, size * 0.03), lineCap: .round))
            .frame(width: size, height: size)
            .accessibilityLabel("khensu.nu")
    }
}

// MARK: Glass that steps aside for video

extension EnvironmentValues {
    /// Set by every video surface (livestreams, playing video, video calls).
    /// Glass re-samples each video frame, so views under this flag use plain
    /// translucent fills instead (PLAN.md, "Glass avatars and message bubbles").
    @Entry var isOverVideo = false
}

extension View {
    /// Liquid Glass in `shape`, or a plain translucent fill when over video.
    func khensuGlass<S: Shape>(tint: Color? = nil, in shape: S) -> some View {
        modifier(KhensuGlass(tint: tint, shape: shape))
    }

    /// Marks a subtree as drawn over video.
    func videoSurface() -> some View { environment(\.isOverVideo, true) }
}

private struct KhensuGlass<S: Shape>: ViewModifier {
    @Environment(\.isOverVideo) private var isOverVideo
    let tint: Color?
    let shape: S

    func body(content: Content) -> some View {
        if isOverVideo {
            content.background((tint ?? .white).opacity(0.14), in: shape)
        } else {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        }
    }
}

/// Glass avatar with initials.
struct Avatar: View {
    let title: String
    var size: CGFloat = 48
    var kind: Kind = .person

    enum Kind { case person, group, channel, notes }

    var body: some View {
        ZStack {
            switch kind {
            case .notes:
                Image(systemName: "bookmark.fill").font(.system(size: size * 0.38, weight: .semibold))
            case .channel:
                Image(systemName: "megaphone.fill").font(.system(size: size * 0.36, weight: .semibold))
            default:
                Text(initials).font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(Palette.starlight)
        .frame(width: size, height: size)
        .khensuGlass(tint: Palette.silver.opacity(0.15), in: Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = title.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}
