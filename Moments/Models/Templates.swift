// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftUI

/// A declarative layout pack. Fetched packs stay content-addressed later; these ship in the app.
struct MomentTemplate: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Sendable, Codable { case reel, carousel, story }
    enum Mood: String, Sendable, Codable { case minimal, bold, editorial, film, night }

    let id: String
    let title: String
    let blurb: String
    let kind: Kind
    let mood: Mood
    let clipSlots: Int
    let defaultCaption: String
    let accentR: Double
    let accentG: Double
    let accentB: Double

    var accent: Color { Color(red: accentR, green: accentG, blue: accentB) }

    /// The treatment this pack actually applies in preview + export.
    var look: MomentLook {
        switch mood {
        case .film: .film
        case .night: .haze
        case .editorial: .printed
        case .bold: .digitalPop
        case .minimal: .natural
        }
    }
    var transition: MomentTransition {
        switch mood {
        case .minimal, .editorial: .cut
        case .film: .dip
        case .bold, .night: .fade
        }
    }
    var defaultCaptionStyle: CaptionStyle {
        switch mood {
        case .film: .soft
        case .editorial: .stamp
        case .minimal: .typewriter
        case .bold, .night: .pop
        }
    }

    static let catalogue: [MomentTemplate] = [
        .init(id: "pulse", title: "Pulse", blurb: "Beat-led cuts for day-in-the-life clips.", kind: .reel, mood: .bold, clipSlots: 8, defaultCaption: "on the beat", accentR: 0.94, accentG: 0.66, accentB: 0.78),
        .init(id: "scrapbook", title: "Scrapbook", blurb: "Three-slide dump with soft paper grain.", kind: .carousel, mood: .editorial, clipSlots: 3, defaultCaption: "kept this", accentR: 0.49, accentG: 0.88, accentB: 0.78),
        .init(id: "night-bus", title: "Night bus", blurb: "Vertical story with haze and captions.", kind: .story, mood: .night, clipSlots: 5, defaultCaption: "still awake", accentR: 0.55, accentG: 0.7, accentB: 1),
        .init(id: "clean-cut", title: "Clean cut", blurb: "Minimal hard cuts. No overlays.", kind: .reel, mood: .minimal, clipSlots: 6, defaultCaption: "", accentR: 1, accentG: 1, accentB: 1),
        .init(id: "film-still", title: "Film still", blurb: "Printed look, soft vignette, quiet type.", kind: .carousel, mood: .film, clipSlots: 4, defaultCaption: "take one", accentR: 0.95, accentG: 0.85, accentB: 0.7),
        .init(id: "tutorial", title: "Tutorial", blurb: "Numbered slides for how-tos.", kind: .carousel, mood: .bold, clipSlots: 5, defaultCaption: "step", accentR: 0.7, accentG: 0.95, accentB: 0.55),
    ]
}


enum MomentLook: String, CaseIterable, Identifiable, Sendable, Codable {
    case natural, film, printed, haze, digitalPop, vhs, mono
    var id: String { rawValue }
    var label: String {
        switch self {
        case .natural: "Natural"; case .film: "Film 35mm"; case .printed: "Printed"
        case .haze: "Haze"; case .digitalPop: "Digital Pop"; case .vhs: "VHS"; case .mono: "Mono"
        }
    }
}

enum MomentTransition: String, CaseIterable, Identifiable, Sendable, Codable {
    case cut, fade, dip
    var id: String { rawValue }
    var label: String { switch self { case .cut: "Hard cut"; case .fade: "Fade"; case .dip: "Dip to black" } }
}

enum ProjectFormat: String, CaseIterable, Identifiable, Sendable, Codable {
    case portrait, square, story, wide
    var id: String { rawValue }
    var label: String { switch self { case .portrait: "9:16"; case .square: "1:1"; case .story: "4:5"; case .wide: "16:9" } }
    var size: CGSize { switch self {
        case .portrait: CGSize(width: 1080, height: 1920)
        case .square: CGSize(width: 1080, height: 1080)
        case .story: CGSize(width: 1080, height: 1350)
        case .wide: CGSize(width: 1920, height: 1080)
    } }
}
