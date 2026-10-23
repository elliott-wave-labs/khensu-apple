// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// A point in canvas space, 0…1 on each axis, origin top-left (as you see it on screen).
struct NormPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

// MARK: - Text

enum TextFont: String, CaseIterable, Identifiable, Codable, Sendable {
    case sans, rounded, serif, mono, condensed, didot, futura, marker, script, typewriter, chalk, gill, copperplate, noteworthy, georgia, bradley
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sans: "Sans"; case .rounded: "Rounded"; case .serif: "Serif"; case .mono: "Mono"
        case .condensed: "Condensed"; case .didot: "Didot"; case .futura: "Futura"; case .marker: "Marker"
        case .script: "Script"; case .typewriter: "Typewriter"; case .chalk: "Chalk"; case .gill: "Gill"
        case .copperplate: "Copperplate"; case .noteworthy: "Noteworthy"; case .georgia: "Georgia"; case .bradley: "Hand"
        }
    }
    /// PostScript name for named faces; nil means a system design.
    var postScript: String? {
        switch self {
        case .sans, .rounded, .serif, .mono: nil
        case .condensed: "AvenirNextCondensed-Heavy"
        case .didot: "Didot-Bold"
        case .futura: "Futura-Bold"
        case .marker: "MarkerFelt-Wide"
        case .script: "SnellRoundhand-Black"
        case .typewriter: "AmericanTypewriter-Bold"
        case .chalk: "Chalkduster"
        case .gill: "GillSans-UltraBold"
        case .copperplate: "Copperplate-Bold"
        case .noteworthy: "Noteworthy-Bold"
        case .georgia: "Georgia-Bold"
        case .bradley: "BradleyHandITCTT-Bold"
        }
    }
}

/// In and out animations for text, stickers, overlays and clips.
enum MotionAnim: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, fade, pop, zoomIn, zoomOut, slideUp, slideDown, slideLeft, slideRight, typewriter, bounce, spin, blur, flash, whip, drop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "None"; case .fade: "Fade"; case .pop: "Pop"; case .zoomIn: "Zoom in"; case .zoomOut: "Zoom out"
        case .slideUp: "Slide up"; case .slideDown: "Slide down"; case .slideLeft: "Slide left"; case .slideRight: "Slide right"
        case .typewriter: "Typewriter"; case .bounce: "Bounce"; case .spin: "Spin"; case .blur: "Blur"; case .flash: "Flash"
        case .whip: "Whip"; case .drop: "Drop"
        }
    }
}

/// How a media overlay is cut out from its own background.
enum MediaKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, greenScreen, cutout
    var id: String { rawValue }
    var label: String { switch self { case .none: "None"; case .greenScreen: "Green screen"; case .cutout: "Cutout (person)" } }
}

enum OverlayKind: String, Codable, Sendable { case text, sticker, media, drawing }

/// Anything laid over the timeline: text, a sticker or cutout, a drawing, or a photo/video overlay (picture in picture).
struct MomentOverlay: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var kind: OverlayKind
    var text: String = ""
    var font: TextFont = .sans
    var colorHex: String = "FFFFFF"
    /// Box behind the text; nil for none.
    var boxHex: String? = nil
    var outline: Bool = false
    /// Font size in points at 1080 px canvas width.
    var fontSize: Double = 72
    /// File name in the media folder (sticker / drawing PNG, or overlay photo/video).
    var mediaName: String? = nil
    var mediaIsVideo: Bool = false
    var center = NormPoint(x: 0.5, y: 0.5)
    var scale: Double = 1
    var rotation: Double = 0
    /// Width as a fraction of the canvas width (stickers and media).
    var widthFrac: Double = 0.42
    var start: Double = 0
    var duration: Double = 3
    var animIn: MotionAnim = .pop
    var animOut: MotionAnim = .fade
    var key: MediaKey = .none
    var opacity: Double = 1
    /// Times are seconds from the overlay's start. Nil or empty means the base values hold throughout.
    var keyframes: [OverlayKeyframe]? = nil

    var mediaURL: URL? { mediaName.map { MediaImport.mediaDir.appendingPathComponent($0) } }
}

// MARK: - Keyframes

enum KeyEase: String, CaseIterable, Identifiable, Codable, Sendable {
    case linear, easeIn, easeOut, easeInOut, hold
    var id: String { rawValue }
    var label: String {
        switch self { case .linear: "Linear"; case .easeIn: "Ease in"; case .easeOut: "Ease out"; case .easeInOut: "Smooth"; case .hold: "Hold" }
    }
    func apply(_ u: Double) -> Double {
        let u = min(1, max(0, u))
        switch self {
        case .linear: return u
        case .easeIn: return u * u * u
        case .easeOut: return 1 - pow(1 - u, 3)
        case .easeInOut: return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
        case .hold: return 0
        }
    }
}

struct OverlayKeyframe: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var t: Double
    var center: NormPoint
    var scale: Double
    var rotation: Double
    var opacity: Double
    /// Easing from this keyframe to the next.
    var ease: KeyEase = .easeInOut
}

/// Zoom, offset (fraction of the frame, y down), rotation in degrees and opacity, on top of the clip's placement.
struct ClipKeyframe: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var t: Double
    var zoom: Double = 1
    var x: Double = 0
    var y: Double = 0
    var rotation: Double = 0
    var opacity: Double = 1
    var ease: KeyEase = .easeInOut
}

enum Keyframes {
    /// Index of the segment around `t` and the eased progress within it.
    private static func segment(_ times: [Double], eases: [KeyEase], at t: Double) -> (Int, Int, Double) {
        guard let first = times.first, let last = times.last else { return (0, 0, 0) }
        if t <= first { return (0, 0, 0) }
        if t >= last { return (times.count - 1, times.count - 1, 0) }
        let i = (times.lastIndex { $0 <= t }) ?? 0
        let j = min(i + 1, times.count - 1)
        let span = max(1e-6, times[j] - times[i])
        return (i, j, eases[i].apply((t - times[i]) / span))
    }

    static func overlay(_ o: MomentOverlay, at local: Double) -> (center: NormPoint, scale: Double, rotation: Double, opacity: Double) {
        guard let keys = o.keyframes?.sorted(by: { $0.t < $1.t }), !keys.isEmpty else { return (o.center, o.scale, o.rotation, o.opacity) }
        let (i, j, u) = segment(keys.map(\.t), eases: keys.map(\.ease), at: local)
        let a = keys[i], b = keys[j]
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
        return (NormPoint(x: mix(a.center.x, b.center.x), y: mix(a.center.y, b.center.y)),
                mix(a.scale, b.scale), mix(a.rotation, b.rotation), mix(a.opacity, b.opacity))
    }

    static func clip(_ keys: [ClipKeyframe], at local: Double) -> ClipKeyframe? {
        let keys = keys.sorted { $0.t < $1.t }
        guard !keys.isEmpty else { return nil }
        let (i, j, u) = segment(keys.map(\.t), eases: keys.map(\.ease), at: local)
        let a = keys[i], b = keys[j]
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * u }
        return ClipKeyframe(t: local, zoom: mix(a.zoom, b.zoom), x: mix(a.x, b.x), y: mix(a.y, b.y),
                            rotation: mix(a.rotation, b.rotation), opacity: mix(a.opacity, b.opacity), ease: a.ease)
    }
}

// MARK: - Effects

enum EffectGroup: String, CaseIterable, Identifiable, Codable, Sendable {
    case motion, light, color, retro, distort, prism, blur
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum EffectKind: String, CaseIterable, Identifiable, Codable, Sendable {
    // motion
    case zoomPulse, heartbeat, shake, earthquake, slowZoom, spinIn, bounce, strobe
    // light
    case flash, lightLeak, glow, bloom, sparkle, sunFlare, neonEdges, spotlight
    // color
    case noir, chrome, faded, instant, tonal, sepia, invert, rainbowShift, thermal, duotone, posterize, warmth, cool, tealOrange
    // retro
    case rgbSplit, glitch, grain, vhsLines, halftone, letterbox, vignette, comic, dots
    // distort
    case mirror, mirrorVertical, quad, kaleidoscope, twirl, bulge, pinch, pixelate, hexagon, crystal, fisheye
    // prism
    case prism, prismTunnel, facets, triangles
    // blur
    case blurIn, zoomBlur, motionBlur, dreamy, tiltShift, sharpen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zoomPulse: "Zoom pulse"; case .heartbeat: "Heartbeat"; case .shake: "Shake"; case .earthquake: "Earthquake"
        case .slowZoom: "Slow zoom"; case .spinIn: "Spin"; case .bounce: "Bounce"; case .strobe: "Strobe"
        case .flash: "Flash"; case .lightLeak: "Light leak"; case .glow: "Glow"; case .bloom: "Bloom"; case .sparkle: "Sparkle"
        case .sunFlare: "Sun flare"; case .neonEdges: "Neon edges"; case .spotlight: "Spotlight"
        case .noir: "Noir"; case .chrome: "Chrome"; case .faded: "Faded"; case .instant: "Instant"; case .tonal: "Tonal"
        case .sepia: "Sepia"; case .invert: "Invert"; case .rainbowShift: "Rainbow shift"; case .thermal: "Thermal"
        case .duotone: "Duotone"; case .posterize: "Posterize"; case .warmth: "Warm"; case .cool: "Cool"; case .tealOrange: "Teal & orange"
        case .rgbSplit: "RGB split"; case .glitch: "Glitch"; case .grain: "Film grain"; case .vhsLines: "VHS lines"
        case .halftone: "Halftone"; case .letterbox: "Letterbox"; case .vignette: "Vignette"; case .comic: "Comic"; case .dots: "Dot screen"
        case .mirror: "Mirror"; case .mirrorVertical: "Mirror vertical"; case .quad: "Quad"; case .kaleidoscope: "Kaleidoscope"
        case .twirl: "Twirl"; case .bulge: "Bulge"; case .pinch: "Pinch"; case .pixelate: "Pixelate"; case .hexagon: "Hexagons"
        case .crystal: "Crystal"; case .fisheye: "Fisheye"
        case .prism: "Prism glass"; case .prismTunnel: "Prism tunnel"; case .facets: "Glass facets"; case .triangles: "Triangles"
        case .blurIn: "Blur in"; case .zoomBlur: "Zoom blur"; case .motionBlur: "Motion blur"; case .dreamy: "Dreamy"
        case .tiltShift: "Tilt-shift"; case .sharpen: "Sharpen"
        }
    }

    var group: EffectGroup {
        switch self {
        case .zoomPulse, .heartbeat, .shake, .earthquake, .slowZoom, .spinIn, .bounce, .strobe: .motion
        case .flash, .lightLeak, .glow, .bloom, .sparkle, .sunFlare, .neonEdges, .spotlight: .light
        case .noir, .chrome, .faded, .instant, .tonal, .sepia, .invert, .rainbowShift, .thermal, .duotone, .posterize, .warmth, .cool, .tealOrange: .color
        case .rgbSplit, .glitch, .grain, .vhsLines, .halftone, .letterbox, .vignette, .comic, .dots: .retro
        case .mirror, .mirrorVertical, .quad, .kaleidoscope, .twirl, .bulge, .pinch, .pixelate, .hexagon, .crystal, .fisheye: .distort
        case .prism, .prismTunnel, .facets, .triangles: .prism
        case .blurIn, .zoomBlur, .motionBlur, .dreamy, .tiltShift, .sharpen: .blur
        }
    }

    var symbol: String {
        switch group {
        case .motion: "move.3d"; case .light: "sun.max"; case .color: "paintpalette"
        case .retro: "tv"; case .distort: "circle.hexagongrid"; case .prism: "rhombus"; case .blur: "drop"
        }
    }
}

/// An effect over a span of the timeline, or across all of it (an adjustment layer).
struct MomentEffect: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var kind: EffectKind
    var intensity: Double = 0.7
    var start: Double = 0
    var duration: Double = 2
    var wholeTimeline: Bool = false
    /// Effect speed for animated effects (pulses, strobes, shifts).
    var speed: Double = 1
}

// MARK: - Clip settings

enum ClipMotion: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, zoomIn, zoomOut, panLeft, panRight, panUp, panDown, drift
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Still"; case .zoomIn: "Push in"; case .zoomOut: "Pull out"; case .panLeft: "Pan left"
        case .panRight: "Pan right"; case .panUp: "Tilt up"; case .panDown: "Tilt down"; case .drift: "Drift"
        }
    }
}

enum ClipBackground: String, CaseIterable, Identifiable, Codable, Sendable {
    case fill, fit, blurFill, cutout, greenScreen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fill: "Fill"; case .fit: "Fit"; case .blurFill: "Fit on blur"; case .cutout: "Cutout"; case .greenScreen: "Green screen"
        }
    }
}

struct ClipAdjust: Codable, Hashable, Sendable {
    var exposure: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var warmth: Double = 0
    /// Lifts shadows and adds a soft key light.
    var relight: Double = 0
    var sharpen: Double = 0
    var isNeutral: Bool { self == ClipAdjust() }
}

// MARK: - Layouts (collages)

enum CollageLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case single, splitTopBottom, splitSides, trio, trioStack, grid4, filmstrip, framed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .single: "Single"; case .splitTopBottom: "Top + bottom"; case .splitSides: "Side by side"
        case .trio: "One + two"; case .trioStack: "Three stacked"; case .grid4: "Grid of four"
        case .filmstrip: "Filmstrip"; case .framed: "Framed"
        }
    }
    var symbol: String {
        switch self {
        case .single: "rectangle"; case .splitTopBottom: "rectangle.split.1x2"; case .splitSides: "rectangle.split.2x1"
        case .trio: "rectangle.split.3x1"; case .trioStack: "rectangle.split.1x2.fill"; case .grid4: "square.grid.2x2"
        case .filmstrip: "film"; case .framed: "photo.artframe"
        }
    }
    /// Cells in canvas space, 0…1 top-left origin.
    var cells: [CGRect] {
        let g = 0.012
        switch self {
        case .single: return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case .splitTopBottom: return [CGRect(x: 0, y: 0, width: 1, height: 0.5 - g / 2), CGRect(x: 0, y: 0.5 + g / 2, width: 1, height: 0.5 - g / 2)]
        case .splitSides: return [CGRect(x: 0, y: 0, width: 0.5 - g / 2, height: 1), CGRect(x: 0.5 + g / 2, y: 0, width: 0.5 - g / 2, height: 1)]
        case .trio: return [CGRect(x: 0, y: 0, width: 1, height: 0.6 - g / 2),
                            CGRect(x: 0, y: 0.6 + g / 2, width: 0.5 - g / 2, height: 0.4 - g / 2),
                            CGRect(x: 0.5 + g / 2, y: 0.6 + g / 2, width: 0.5 - g / 2, height: 0.4 - g / 2)]
        case .trioStack: return (0..<3).map { i in CGRect(x: 0, y: Double(i) / 3 + (i == 0 ? 0 : g / 2), width: 1, height: 1 / 3 - g) }
        case .grid4: return [CGRect(x: 0, y: 0, width: 0.5 - g / 2, height: 0.5 - g / 2), CGRect(x: 0.5 + g / 2, y: 0, width: 0.5 - g / 2, height: 0.5 - g / 2),
                             CGRect(x: 0, y: 0.5 + g / 2, width: 0.5 - g / 2, height: 0.5 - g / 2), CGRect(x: 0.5 + g / 2, y: 0.5 + g / 2, width: 0.5 - g / 2, height: 0.5 - g / 2)]
        case .filmstrip: return (0..<3).map { i in CGRect(x: 0.08, y: 0.06 + Double(i) * 0.3, width: 0.84, height: 0.27) }
        case .framed: return [CGRect(x: 0.07, y: 0.07, width: 0.86, height: 0.78)]
        }
    }
    var count: Int { cells.count }
}

// MARK: - Captions

enum CaptionPosition: String, CaseIterable, Identifiable, Codable, Sendable {
    case top, middle, bottom
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var y: Double { switch self { case .top: 0.14; case .middle: 0.5; case .bottom: 0.8 } }
}

struct CaptionLook: Codable, Hashable, Sendable {
    var font: TextFont = .sans
    var colorHex: String = "FFFFFF"
    var position: CaptionPosition = .bottom
    var size: Double = 68
    /// Highlight the current word (karaoke style) for auto captions.
    var wordHighlight: Bool = true
    var highlightHex: String = "F0A8C7"
}

// MARK: - Export

enum ExportResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case hd720, hd1080, uhd4k
    var id: String { rawValue }
    var label: String { switch self { case .hd720: "720p"; case .hd1080: "1080p"; case .uhd4k: "4K" } }
    var scale: Double { switch self { case .hd720: 2.0 / 3.0; case .hd1080: 1; case .uhd4k: 2 } }
}

struct ExportSettings: Codable, Hashable, Sendable {
    var resolution: ExportResolution = .hd1080
    var fps: Int = 30
    var hevc: Bool = true
}

// MARK: - Voice

enum VoiceEffect: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, deep, chipmunk, robot, echo, hall, radio, telephone, megaphone, alien, whisper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Natural"; case .deep: "Deep"; case .chipmunk: "Chipmunk"; case .robot: "Robot"; case .echo: "Echo"
        case .hall: "Big hall"; case .radio: "Radio"; case .telephone: "Telephone"; case .megaphone: "Megaphone"
        case .alien: "Alien"; case .whisper: "Airy"
        }
    }
}

// MARK: - Kits and ideas

/// Saved colours, text style, caption style, look, effects and audio, reusable on any project.
struct MomentKit: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var look: MomentLook
    var captionLook: CaptionLook
    var captionStyle: CaptionStyle
    var textFont: TextFont
    var textColorHex: String
    var textBoxHex: String?
    var palette: [String]
    var effects: [EffectKind]
    var musicName: String?
    var created = Date()
}

struct MomentIdea: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var mediaName: String? = nil
    var mediaIsVideo = false
    var done = false
    var created = Date()
    var mediaURL: URL? { mediaName.map { MediaImport.mediaDir.appendingPathComponent($0) } }
}

// MARK: - Colour helpers

enum Hex {
    static func rgba(_ hex: String) -> (Double, Double, Double, Double) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 6 { s += "FF" }
        guard s.count == 8, let v = UInt64(s, radix: 16) else { return (1, 1, 1, 1) }
        return (Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
    static func cg(_ hex: String) -> CGColor {
        let c = rgba(hex)
        return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
    }
    static let palette = ["FFFFFF", "0A0B0D", "F0A8C7", "7DE0C7", "8CB3FF", "FFD66B", "FF6B5B", "B892FF", "F2D9B3", "A8F07D"]
}
