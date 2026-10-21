// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftUI

enum TemplateCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case trending, memories, stories, lifestyle, travel, beauty, love, sport, motivation, inspiration, mood, marketing, business, seasonal, holidays, hygge, food, style, collage, tutorial
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// A declarative pack: look, transition, layout, motion, effects and a title. Everything it sets renders in preview and export.
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
    var category: TemplateCategory = .lifestyle
    var lookOverride: MomentLook? = nil
    var transitionOverride: MomentTransition? = nil
    var layout: CollageLayout = .single
    var motion: ClipMotion = .none
    var clipAnimIn: MotionAnim = .none
    var effects: [EffectKind] = []
    var titleText: String? = nil
    var titleFont: TextFont = .sans
    var format: ProjectFormat = .portrait

    init(id: String, title: String, blurb: String, kind: Kind, mood: Mood, clipSlots: Int, defaultCaption: String,
         accentR: Double, accentG: Double, accentB: Double, category: TemplateCategory = .lifestyle,
         look: MomentLook? = nil, transition: MomentTransition? = nil, layout: CollageLayout = .single,
         motion: ClipMotion = .none, clipAnimIn: MotionAnim = .none, effects: [EffectKind] = [],
         titleText: String? = nil, titleFont: TextFont = .sans, format: ProjectFormat = .portrait) {
        self.id = id; self.title = title; self.blurb = blurb; self.kind = kind; self.mood = mood
        self.clipSlots = clipSlots; self.defaultCaption = defaultCaption
        self.accentR = accentR; self.accentG = accentG; self.accentB = accentB
        self.category = category; self.lookOverride = look; self.transitionOverride = transition
        self.layout = layout; self.motion = motion; self.clipAnimIn = clipAnimIn; self.effects = effects
        self.titleText = titleText; self.titleFont = titleFont; self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, blurb, kind, mood, clipSlots, defaultCaption, accentR, accentG, accentB
        case category, lookOverride, transitionOverride, layout, motion, clipAnimIn, effects, titleText, titleFont, format
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        blurb = try c.decode(String.self, forKey: .blurb)
        kind = try c.decode(Kind.self, forKey: .kind)
        mood = try c.decode(Mood.self, forKey: .mood)
        clipSlots = try c.decode(Int.self, forKey: .clipSlots)
        defaultCaption = try c.decode(String.self, forKey: .defaultCaption)
        accentR = try c.decode(Double.self, forKey: .accentR)
        accentG = try c.decode(Double.self, forKey: .accentG)
        accentB = try c.decode(Double.self, forKey: .accentB)
        category = try c.decodeIfPresent(TemplateCategory.self, forKey: .category) ?? .lifestyle
        lookOverride = try c.decodeIfPresent(MomentLook.self, forKey: .lookOverride)
        transitionOverride = try c.decodeIfPresent(MomentTransition.self, forKey: .transitionOverride)
        layout = try c.decodeIfPresent(CollageLayout.self, forKey: .layout) ?? .single
        motion = try c.decodeIfPresent(ClipMotion.self, forKey: .motion) ?? .none
        clipAnimIn = try c.decodeIfPresent(MotionAnim.self, forKey: .clipAnimIn) ?? .none
        effects = try c.decodeIfPresent([EffectKind].self, forKey: .effects) ?? []
        titleText = try c.decodeIfPresent(String.self, forKey: .titleText)
        titleFont = try c.decodeIfPresent(TextFont.self, forKey: .titleFont) ?? .sans
        format = try c.decodeIfPresent(ProjectFormat.self, forKey: .format) ?? .portrait
    }

    var accent: Color { Color(red: accentR, green: accentG, blue: accentB) }
    var accentHex: String { String(format: "%02X%02X%02X", Int(accentR * 255), Int(accentG * 255), Int(accentB * 255)) }

    var look: MomentLook {
        if let lookOverride { return lookOverride }
        switch mood {
        case .film: return .film
        case .night: return .haze
        case .editorial: return .printed
        case .bold: return .digitalPop
        case .minimal: return .natural
        }
    }
    var transition: MomentTransition {
        if let transitionOverride { return transitionOverride }
        switch mood {
        case .minimal, .editorial: return .cut
        case .film: return .dip
        case .bold, .night: return .fade
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
        // Original six
        .init(id: "pulse", title: "Pulse", blurb: "Beat-led cuts for day-in-the-life clips.", kind: .reel, mood: .bold, clipSlots: 8, defaultCaption: "on the beat", accentR: 0.94, accentG: 0.66, accentB: 0.78, category: .trending, clipAnimIn: .zoomOut, effects: [.zoomPulse]),
        .init(id: "scrapbook", title: "Scrapbook", blurb: "Three-slide dump with soft paper grain.", kind: .carousel, mood: .editorial, clipSlots: 3, defaultCaption: "kept this", accentR: 0.49, accentG: 0.88, accentB: 0.78, category: .memories, layout: .framed, motion: .drift, effects: [.grain], titleText: "kept this", titleFont: .marker),
        .init(id: "night-bus", title: "Night bus", blurb: "Vertical story with haze and captions.", kind: .story, mood: .night, clipSlots: 5, defaultCaption: "still awake", accentR: 0.55, accentG: 0.7, accentB: 1, category: .mood, motion: .zoomIn, effects: [.glow]),
        .init(id: "clean-cut", title: "Clean cut", blurb: "Minimal hard cuts. No overlays.", kind: .reel, mood: .minimal, clipSlots: 6, defaultCaption: "", accentR: 1, accentG: 1, accentB: 1, category: .business),
        .init(id: "film-still", title: "Film still", blurb: "Printed look, soft vignette, quiet type.", kind: .carousel, mood: .film, clipSlots: 4, defaultCaption: "take one", accentR: 0.95, accentG: 0.85, accentB: 0.7, category: .inspiration, motion: .drift, effects: [.grain, .letterbox], titleFont: .didot),
        .init(id: "tutorial", title: "Tutorial", blurb: "Numbered steps for how-tos.", kind: .carousel, mood: .bold, clipSlots: 5, defaultCaption: "step", accentR: 0.7, accentG: 0.95, accentB: 0.55, category: .tutorial, titleText: "how to", titleFont: .condensed),

        // Trending
        .init(id: "glitch-drop", title: "Glitch drop", blurb: "RGB split and glitch on every cut.", kind: .reel, mood: .bold, clipSlots: 8, defaultCaption: "wait for it", accentR: 0.55, accentG: 1, accentB: 0.9, category: .trending, look: .vhs, transition: .cut, clipAnimIn: .whip, effects: [.glitch, .rgbSplit]),
        .init(id: "cutout-pop", title: "Cutout pop", blurb: "You, lifted off the background, over a colour block.", kind: .reel, mood: .bold, clipSlots: 4, defaultCaption: "main character", accentR: 1, accentG: 0.84, accentB: 0.42, category: .trending, look: .digitalPop, clipAnimIn: .pop, titleText: "main character", titleFont: .condensed),
        .init(id: "photo-dump", title: "Photo dump", blurb: "Fast photo cuts with push-ins.", kind: .reel, mood: .bold, clipSlots: 12, defaultCaption: "", accentR: 0.98, accentG: 0.6, accentB: 0.45, category: .trending, look: .instant, transition: .cut, motion: .zoomIn, effects: [.flash]),
        // Memories
        .init(id: "one-year-ago", title: "One year ago", blurb: "Soft fades and warm grain for looking back.", kind: .reel, mood: .film, clipSlots: 8, defaultCaption: "one year ago", accentR: 0.96, accentG: 0.8, accentB: 0.62, category: .memories, look: .faded, motion: .drift, effects: [.lightLeak, .grain], titleText: "one year ago", titleFont: .script),
        .init(id: "polaroids", title: "Polaroids", blurb: "Framed instant prints that drop in.", kind: .carousel, mood: .editorial, clipSlots: 6, defaultCaption: "", accentR: 0.98, accentG: 0.96, accentB: 0.9, category: .memories, look: .instant, layout: .framed, clipAnimIn: .drop, titleFont: .marker),
        // Stories
        .init(id: "story-split", title: "Story split", blurb: "Two moments at once, top and bottom.", kind: .story, mood: .minimal, clipSlots: 6, defaultCaption: "", accentR: 0.8, accentG: 0.85, accentB: 1, category: .stories, layout: .splitTopBottom, clipAnimIn: .slideUp),
        .init(id: "story-quote", title: "Quote card", blurb: "A line of text over slow footage.", kind: .story, mood: .film, clipSlots: 2, defaultCaption: "", accentR: 0.95, accentG: 0.9, accentB: 0.8, category: .stories, motion: .zoomIn, effects: [.dreamy], titleText: "say it plainly", titleFont: .georgia),
        // Lifestyle
        .init(id: "day-in-life", title: "Day in my life", blurb: "Timestamps, quick cuts and a soft look.", kind: .reel, mood: .minimal, clipSlots: 10, defaultCaption: "7:00 am", accentR: 0.9, accentG: 0.88, accentB: 0.8, category: .lifestyle, look: .warm, transition: .fade, titleText: "a day in my life", titleFont: .typewriter),
        .init(id: "grwm", title: "Get ready with me", blurb: "Mirror-friendly cuts with a glow.", kind: .reel, mood: .bold, clipSlots: 8, defaultCaption: "grwm", accentR: 0.98, accentG: 0.7, accentB: 0.8, category: .beauty, look: .pastel, clipAnimIn: .zoomOut, effects: [.glow], titleText: "grwm", titleFont: .rounded),
        // Travel
        .init(id: "postcard", title: "Postcard", blurb: "Wide shots, drift and a stamped title.", kind: .reel, mood: .film, clipSlots: 8, defaultCaption: "wish you were here", accentR: 0.55, accentG: 0.8, accentB: 0.95, category: .travel, look: .tealOrange, motion: .drift, effects: [.letterbox], titleText: "wish you were here", titleFont: .copperplate),
        .init(id: "passport", title: "Passport", blurb: "Grid of four places, one per beat.", kind: .reel, mood: .bold, clipSlots: 8, defaultCaption: "", accentR: 0.4, accentG: 0.75, accentB: 1, category: .travel, layout: .grid4, clipAnimIn: .pop),
        // Beauty
        .init(id: "before-after", title: "Before / after", blurb: "Side by side, then the reveal.", kind: .reel, mood: .minimal, clipSlots: 2, defaultCaption: "before / after", accentR: 1, accentG: 0.8, accentB: 0.85, category: .beauty, layout: .splitSides, titleText: "before   after", titleFont: .futura),
        // Love
        .init(id: "us", title: "Us", blurb: "Slow push-ins, warm light, a soft script.", kind: .reel, mood: .film, clipSlots: 8, defaultCaption: "us", accentR: 1, accentG: 0.6, accentB: 0.7, category: .love, look: .warm, motion: .zoomIn, effects: [.bloom], titleText: "us", titleFont: .script),
        // Sport
        .init(id: "highlight", title: "Highlight reel", blurb: "Shake on the hits, slow-mo ready.", kind: .reel, mood: .bold, clipSlots: 8, defaultCaption: "", accentR: 1, accentG: 0.45, accentB: 0.35, category: .sport, look: .chrome, transition: .cut, clipAnimIn: .whip, effects: [.shake, .zoomBlur], titleFont: .condensed),
        // Motivation
        .init(id: "rise", title: "Rise", blurb: "Big type, strobe hits, high contrast.", kind: .reel, mood: .bold, clipSlots: 6, defaultCaption: "keep going", accentR: 1, accentG: 0.85, accentB: 0.3, category: .motivation, look: .noir, transition: .cut, effects: [.strobe], titleText: "keep going", titleFont: .condensed),
        // Inspiration
        .init(id: "moodboard", title: "Moodboard", blurb: "Three stacked frames, slow and quiet.", kind: .reel, mood: .editorial, clipSlots: 6, defaultCaption: "", accentR: 0.85, accentG: 0.8, accentB: 0.7, category: .inspiration, look: .matte, layout: .trioStack, motion: .drift),
        // Mood
        .init(id: "after-hours", title: "After hours", blurb: "Neon edges and haze for night clips.", kind: .reel, mood: .night, clipSlots: 6, defaultCaption: "after hours", accentR: 0.7, accentG: 0.5, accentB: 1, category: .mood, look: .cool, effects: [.neonEdges, .vignette]),
        // Marketing & business
        .init(id: "launch", title: "Product launch", blurb: "Title card, clean cuts, call to action.", kind: .reel, mood: .minimal, clipSlots: 6, defaultCaption: "available now", accentR: 0.55, accentG: 0.95, accentB: 0.75, category: .marketing, transition: .cut, clipAnimIn: .slideLeft, titleText: "new", titleFont: .futura),
        .init(id: "sale", title: "Sale", blurb: "Bold colour blocks and a price that pops.", kind: .reel, mood: .bold, clipSlots: 5, defaultCaption: "this week only", accentR: 1, accentG: 0.35, accentB: 0.4, category: .marketing, look: .digitalPop, clipAnimIn: .pop, effects: [.zoomPulse], titleText: "sale", titleFont: .condensed),
        .init(id: "behind-scenes", title: "Behind the scenes", blurb: "Filmstrip frames for the making-of.", kind: .reel, mood: .editorial, clipSlots: 6, defaultCaption: "", accentR: 0.9, accentG: 0.9, accentB: 0.9, category: .business, layout: .filmstrip, effects: [.grain]),
        // Seasonal and holidays
        .init(id: "spooky", title: "Spooky season", blurb: "Costume reveals, flicker and a cold tint.", kind: .reel, mood: .night, clipSlots: 6, defaultCaption: "boo", accentR: 1, accentG: 0.55, accentB: 0.15, category: .seasonal, look: .cool, transition: .dip, clipAnimIn: .flash, effects: [.strobe, .vignette, .grain], titleText: "spooky season", titleFont: .chalk),
        .init(id: "autumn", title: "Cosy autumn", blurb: "Warm grain, slow drift, soft leaks.", kind: .reel, mood: .film, clipSlots: 8, defaultCaption: "", accentR: 0.95, accentG: 0.6, accentB: 0.3, category: .seasonal, look: .warm, motion: .drift, effects: [.lightLeak, .grain]),
        .init(id: "summer-recap", title: "Summer recap", blurb: "Grid of four with a sun flare.", kind: .reel, mood: .bold, clipSlots: 8, defaultCaption: "summer", accentR: 1, accentG: 0.8, accentB: 0.35, category: .seasonal, look: .tealOrange, layout: .grid4, effects: [.sunFlare], titleText: "summer", titleFont: .bradley),
        .init(id: "new-year", title: "New year", blurb: "Countdown cuts with sparkle.", kind: .reel, mood: .bold, clipSlots: 10, defaultCaption: "here's to next year", accentR: 1, accentG: 0.88, accentB: 0.5, category: .holidays, look: .chrome, clipAnimIn: .zoomOut, effects: [.sparkle, .flash], titleText: "happy new year", titleFont: .didot),
        .init(id: "holiday-card", title: "Holiday card", blurb: "Framed, warm and slow.", kind: .carousel, mood: .film, clipSlots: 4, defaultCaption: "", accentR: 0.85, accentG: 0.3, accentB: 0.3, category: .holidays, look: .warm, layout: .framed, motion: .zoomIn, effects: [.sparkle], titleText: "warm wishes", titleFont: .script),
        // Hygge, food, style
        .init(id: "slow-sunday", title: "Slow Sunday", blurb: "Candlelight warmth and long fades.", kind: .reel, mood: .film, clipSlots: 6, defaultCaption: "", accentR: 0.95, accentG: 0.75, accentB: 0.55, category: .hygge, look: .faded, transition: .fade, motion: .zoomIn, effects: [.glow]),
        .init(id: "recipe", title: "Recipe", blurb: "Step titles over overhead shots.", kind: .reel, mood: .minimal, clipSlots: 8, defaultCaption: "step 1", accentR: 0.6, accentG: 0.9, accentB: 0.5, category: .food, look: .warm, clipAnimIn: .slideUp, titleText: "recipe", titleFont: .noteworthy),
        .init(id: "fit-check", title: "Fit check", blurb: "Hard cuts on the beat, pose by pose.", kind: .reel, mood: .bold, clipSlots: 8, defaultCaption: "fit check", accentR: 0.95, accentG: 0.95, accentB: 0.95, category: .style, look: .noir, transition: .cut, clipAnimIn: .zoomIn, effects: [.zoomPulse, .flash], titleText: "fit check", titleFont: .condensed),
        // Collage
        .init(id: "one-plus-two", title: "One + two", blurb: "A hero shot over two details.", kind: .reel, mood: .editorial, clipSlots: 6, defaultCaption: "", accentR: 0.8, accentG: 0.9, accentB: 0.85, category: .collage, layout: .trio, clipAnimIn: .fade),
        .init(id: "wide-story", title: "Wide story", blurb: "Horizontal 16:9 for YouTube and desktops.", kind: .reel, mood: .film, clipSlots: 8, defaultCaption: "", accentR: 0.7, accentG: 0.8, accentB: 0.9, category: .travel, look: .tealOrange, motion: .drift, effects: [.letterbox], format: .wide),
    ]
}

enum MomentLook: String, CaseIterable, Identifiable, Sendable, Codable {
    case natural, film, printed, haze, digitalPop, vhs, mono, noir, chrome, faded, instant, warm, cool, tealOrange, pastel, matte
    var id: String { rawValue }
    var label: String {
        switch self {
        case .natural: "Natural"; case .film: "Film 35mm"; case .printed: "Printed"
        case .haze: "Haze"; case .digitalPop: "Digital Pop"; case .vhs: "VHS"; case .mono: "Mono"
        case .noir: "Noir"; case .chrome: "Chrome"; case .faded: "Faded"; case .instant: "Instant"
        case .warm: "Warm"; case .cool: "Cool"; case .tealOrange: "Teal & orange"; case .pastel: "Pastel"; case .matte: "Matte"
        }
    }
}

enum MomentTransition: String, CaseIterable, Identifiable, Sendable, Codable {
    case cut, fade, dip, flash, whip, zoom, slide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cut: "Hard cut"; case .fade: "Fade"; case .dip: "Dip to black"; case .flash: "Flash"
        case .whip: "Whip pan"; case .zoom: "Zoom"; case .slide: "Slide"
        }
    }
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
