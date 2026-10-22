// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import UniformTypeIdentifiers

/// Resolves a stored media URL after an app update moves the container.
enum MediaPath {
    static func resolve(_ url: URL) -> URL {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let moved = MediaImport.mediaDir.appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: moved.path) ? moved : url
    }
}

struct MomentClip: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var url: URL
    var duration: TimeInterval
    var isPhoto: Bool
    /// Start in the source media (seconds).
    var inPoint: TimeInterval
    /// Length on the timeline (seconds).
    var outDuration: TimeInterval
    var speed: Double = 1
    var muted: Bool = false
    var volume: Double = 1
    /// A reversed copy of the source, made on device, used when `reversed` is on.
    var reversed: Bool = false
    var reversedName: String? = nil
    var motion: ClipMotion = .none
    var animIn: MotionAnim = .none
    var animOut: MotionAnim = .none
    var background: ClipBackground = .fill
    var adjust = ClipAdjust()
    /// Processed audio (voice effect / enhance) replacing the clip's own sound.
    var audioName: String? = nil
    /// Times are seconds from the clip's start on the timeline.
    var keyframes: [ClipKeyframe] = []
    /// The photo this clip was restyled or animated from, so it can go back.
    var originalName: String? = nil
    /// The clip's file before a datamosh was baked in.
    var moshSourceName: String? = nil

    init(id: UUID = UUID(), url: URL, duration: TimeInterval, isPhoto: Bool, inPoint: TimeInterval = 0, outDuration: TimeInterval? = nil) {
        self.id = id
        self.url = url
        self.duration = duration
        self.isPhoto = isPhoto
        self.inPoint = inPoint
        self.outDuration = outDuration ?? (isPhoto ? 2.4 : min(duration, 2.4))
    }

    /// The file the renderer reads (reversed copy when reversed).
    var sourceURL: URL {
        if reversed, let reversedName { return MediaImport.mediaDir.appendingPathComponent(reversedName) }
        return url
    }
    var audioURL: URL? { audioName.map { MediaImport.mediaDir.appendingPathComponent($0) } }

    /// A fresh copy with a new identity and the same settings.
    func copy(inPoint: TimeInterval? = nil, outDuration: TimeInterval? = nil) -> MomentClip {
        var c = self
        c = MomentClip(url: url, duration: duration, isPhoto: isPhoto, inPoint: inPoint ?? self.inPoint, outDuration: outDuration ?? self.outDuration)
        c.speed = speed; c.muted = muted; c.volume = volume; c.reversed = reversed; c.reversedName = reversedName
        c.motion = motion; c.animIn = animIn; c.animOut = animOut; c.background = background; c.adjust = adjust; c.audioName = audioName
        c.keyframes = keyframes; c.originalName = originalName; c.moshSourceName = moshSourceName
        return c
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, duration, isPhoto, inPoint, outDuration, speed, muted, volume, reversed, reversedName, motion, animIn, animOut, background, adjust, audioName, keyframes, originalName, moshSourceName
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = MediaPath.resolve(try c.decode(URL.self, forKey: .url))
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        isPhoto = try c.decode(Bool.self, forKey: .isPhoto)
        inPoint = try c.decodeIfPresent(TimeInterval.self, forKey: .inPoint) ?? 0
        outDuration = try c.decode(TimeInterval.self, forKey: .outDuration)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        reversed = try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        reversedName = try c.decodeIfPresent(String.self, forKey: .reversedName)
        motion = try c.decodeIfPresent(ClipMotion.self, forKey: .motion) ?? .none
        animIn = try c.decodeIfPresent(MotionAnim.self, forKey: .animIn) ?? .none
        animOut = try c.decodeIfPresent(MotionAnim.self, forKey: .animOut) ?? .none
        background = try c.decodeIfPresent(ClipBackground.self, forKey: .background) ?? .fill
        adjust = try c.decodeIfPresent(ClipAdjust.self, forKey: .adjust) ?? ClipAdjust()
        audioName = try c.decodeIfPresent(String.self, forKey: .audioName)
        keyframes = (try? c.decodeIfPresent([ClipKeyframe].self, forKey: .keyframes)) ?? []
        originalName = try c.decodeIfPresent(String.self, forKey: .originalName)
        moshSourceName = try c.decodeIfPresent(String.self, forKey: .moshSourceName)
    }
}

struct CaptionWord: Hashable, Sendable, Codable {
    var text: String
    var start: TimeInterval
    var duration: TimeInterval
}

struct MomentCaption: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var text: String
    var style: CaptionStyle
    var start: TimeInterval
    var duration: TimeInterval
    /// Word timings from on-device speech, for word-by-word highlight.
    var words: [CaptionWord] = []

    init(id: UUID = UUID(), text: String, style: CaptionStyle = .pop, start: TimeInterval = 0, duration: TimeInterval = 2.5, words: [CaptionWord] = []) {
        self.id = id
        self.text = text
        self.style = style
        self.start = start
        self.duration = duration
        self.words = words
    }

    private enum CodingKeys: String, CodingKey { case id, text, style, start, duration, words }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        style = try c.decodeIfPresent(CaptionStyle.self, forKey: .style) ?? .pop
        start = try c.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 2.5
        words = try c.decodeIfPresent([CaptionWord].self, forKey: .words) ?? []
    }
}

enum CaptionStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case pop, typewriter, soft, stamp, bold, outline, neon, plain
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pop: "Pop"; case .typewriter: "Typewriter"; case .soft: "Soft"; case .stamp: "Stamp"
        case .bold: "Bold"; case .outline: "Outline"; case .neon: "Neon"; case .plain: "Plain"
        }
    }
}

@Observable
@MainActor
final class MomentProject {
    var id: UUID
    var title: String
    var template: MomentTemplate
    var clips: [MomentClip]
    var captions: [MomentCaption]
    var musicURL: URL?
    var format: ProjectFormat = .portrait
    var look: MomentLook
    var transition: MomentTransition
    var musicVolume: Double = 0.8
    var beatMarks: [TimeInterval]
    var overlays: [MomentOverlay] = []
    var effects: [MomentEffect] = []
    var layout: CollageLayout = .single
    var captionLook = CaptionLook()
    var voiceoverURL: URL?
    var voiceoverVolume: Double = 1
    var export = ExportSettings()
    var folder: String?
    var backdropHex: String = "0A0B0D"
    var created: Date
    var updated: Date

    init(template: MomentTemplate, title: String? = nil) {
        self.id = UUID()
        self.title = title ?? template.title
        self.template = template
        self.clips = []
        self.captions = template.defaultCaption.isEmpty
            ? []
            : [MomentCaption(text: template.defaultCaption, style: template.defaultCaptionStyle)]
        self.musicURL = nil
        self.look = template.look
        self.transition = template.transition
        self.layout = template.layout
        self.format = template.format
        self.beatMarks = []
        self.effects = template.effects.map { MomentEffect(kind: $0, intensity: 0.6, wholeTimeline: true) }
        if let t = template.titleText {
            self.overlays = [MomentOverlay(kind: .text, text: t, font: template.titleFont, colorHex: "FFFFFF",
                                           fontSize: 96, center: NormPoint(x: 0.5, y: 0.22), start: 0, duration: 2.6,
                                           animIn: .pop, animOut: .fade)]
        }
        self.created = .now
        self.updated = .now
        self.captionLook.highlightHex = template.accentHex
    }

    var totalDuration: TimeInterval { Timeline.duration(clips: clips, layout: layout) }

    /// Applies a template's look, transition, layout, motion and effects to clips already in the project.
    func apply(template t: MomentTemplate) {
        template = t
        look = t.look; transition = t.transition; layout = t.layout
        effects.removeAll { $0.wholeTimeline }
        effects += t.effects.map { MomentEffect(kind: $0, intensity: 0.6, wholeTimeline: true) }
        for i in clips.indices {
            if t.motion != .none { clips[i].motion = t.motion }
            if t.clipAnimIn != .none { clips[i].animIn = t.clipAnimIn }
        }
        captionLook.highlightHex = t.accentHex
    }

    func apply(kit: MomentKit) {
        look = kit.look
        captionLook = kit.captionLook
        for i in captions.indices { captions[i].style = kit.captionStyle }
        for i in overlays.indices where overlays[i].kind == .text {
            overlays[i].font = kit.textFont; overlays[i].colorHex = kit.textColorHex; overlays[i].boxHex = kit.textBoxHex
        }
        effects.removeAll { $0.wholeTimeline }
        effects += kit.effects.map { MomentEffect(kind: $0, intensity: 0.6, wholeTimeline: true) }
        if let m = kit.musicName { musicURL = MediaImport.mediaDir.appendingPathComponent(m) }
    }

    func makeKit(named name: String) -> MomentKit {
        let text = overlays.first { $0.kind == .text }
        return MomentKit(name: name, look: look, captionLook: captionLook, captionStyle: captions.first?.style ?? template.defaultCaptionStyle,
                         textFont: text?.font ?? template.titleFont, textColorHex: text?.colorHex ?? "FFFFFF", textBoxHex: text?.boxHex,
                         palette: [template.accentHex, captionLook.colorHex, captionLook.highlightHex, backdropHex],
                         effects: effects.filter(\.wholeTimeline).map(\.kind), musicName: musicURL?.lastPathComponent)
    }

    func touch() { updated = .now }
}

/// Timeline maths shared by the editor and the renderer.
enum Timeline {
    /// Clips grouped into collage cells; a single layout is one clip per group.
    static func groups(_ clips: [MomentClip], layout: CollageLayout) -> [[MomentClip]] {
        let n = max(1, layout.count)
        return stride(from: 0, to: clips.count, by: n).map { Array(clips[$0..<min($0 + n, clips.count)]) }
    }
    static func duration(clips: [MomentClip], layout: CollageLayout) -> TimeInterval {
        groups(clips, layout: layout).reduce(0) { $0 + ($1.map(\.outDuration).max() ?? 0) }
    }
    /// Start time of each clip's group on the timeline.
    static func starts(clips: [MomentClip], layout: CollageLayout) -> [UUID: TimeInterval] {
        var out: [UUID: TimeInterval] = [:]
        var t = 0.0
        for g in groups(clips, layout: layout) {
            for c in g { out[c.id] = t }
            t += g.map(\.outDuration).max() ?? 0
        }
        return out
    }
}

/// Everything persisted for one project.
private struct ProjectDoc: Codable {
    var id: UUID; var title: String; var template: MomentTemplate
    var clips: [MomentClip]; var captions: [MomentCaption]
    var musicPath: String?; var beatMarks: [TimeInterval]
    var created: Date; var updated: Date
    var format: ProjectFormat = .portrait
    var look: MomentLook?
    var transition: MomentTransition?
    var musicVolume: Double = 0.8
    var overlays: [MomentOverlay] = []
    var effects: [MomentEffect] = []
    var layout: CollageLayout = .single
    var captionLook = CaptionLook()
    var voiceoverPath: String?
    var voiceoverVolume: Double = 1
    var export = ExportSettings()
    var folder: String?
    var backdropHex = "0A0B0D"

    @MainActor
    init(_ p: MomentProject) {
        id = p.id; title = p.title; template = p.template; clips = p.clips; captions = p.captions
        musicPath = p.musicURL?.path; beatMarks = p.beatMarks; created = p.created; updated = p.updated
        format = p.format; look = p.look; transition = p.transition; musicVolume = p.musicVolume
        overlays = p.overlays; effects = p.effects; layout = p.layout; captionLook = p.captionLook
        voiceoverPath = p.voiceoverURL?.path; voiceoverVolume = p.voiceoverVolume; export = p.export
        folder = p.folder; backdropHex = p.backdropHex
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, template, clips, captions, musicPath, beatMarks, created, updated, format, look, transition, musicVolume
        case overlays, effects, layout, captionLook, voiceoverPath, voiceoverVolume, export, folder, backdropHex
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        template = try c.decode(MomentTemplate.self, forKey: .template)
        clips = try c.decode([MomentClip].self, forKey: .clips); captions = try c.decode([MomentCaption].self, forKey: .captions)
        musicPath = try c.decodeIfPresent(String.self, forKey: .musicPath)
        beatMarks = try c.decodeIfPresent([TimeInterval].self, forKey: .beatMarks) ?? []
        created = try c.decode(Date.self, forKey: .created); updated = try c.decode(Date.self, forKey: .updated)
        format = try c.decodeIfPresent(ProjectFormat.self, forKey: .format) ?? .portrait
        look = try c.decodeIfPresent(MomentLook.self, forKey: .look)
        transition = try c.decodeIfPresent(MomentTransition.self, forKey: .transition)
        musicVolume = try c.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.8
        overlays = (try? c.decodeIfPresent([MomentOverlay].self, forKey: .overlays)) ?? []
        effects = (try? c.decodeIfPresent([MomentEffect].self, forKey: .effects)) ?? []
        layout = try c.decodeIfPresent(CollageLayout.self, forKey: .layout) ?? .single
        captionLook = (try? c.decodeIfPresent(CaptionLook.self, forKey: .captionLook)) ?? CaptionLook()
        voiceoverPath = try c.decodeIfPresent(String.self, forKey: .voiceoverPath)
        voiceoverVolume = try c.decodeIfPresent(Double.self, forKey: .voiceoverVolume) ?? 1
        export = (try? c.decodeIfPresent(ExportSettings.self, forKey: .export)) ?? ExportSettings()
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        backdropHex = try c.decodeIfPresent(String.self, forKey: .backdropHex) ?? "0A0B0D"
    }

    @MainActor
    func project() -> MomentProject {
        let p = MomentProject(template: template, title: title)
        p.id = id; p.clips = clips; p.captions = captions
        p.musicURL = musicPath.map { MediaPath.resolve(URL(fileURLWithPath: $0)) }
        p.format = format; if let look { p.look = look }; if let transition { p.transition = transition }
        p.musicVolume = musicVolume; p.beatMarks = beatMarks; p.created = created; p.updated = updated
        p.overlays = overlays; p.effects = effects; p.layout = layout; p.captionLook = captionLook
        p.voiceoverURL = voiceoverPath.map { MediaPath.resolve(URL(fileURLWithPath: $0)) }
        p.voiceoverVolume = voiceoverVolume; p.export = export; p.folder = folder; p.backdropHex = backdropHex
        return p
    }
}

@Observable
@MainActor
final class ProjectStore {
    var projects: [MomentProject] = []
    var draft: MomentProject?
    var folders: [String] = []
    var kits: [MomentKit] = []
    var ideas: [MomentIdea] = []

    init() { load() }

    func open(_ template: MomentTemplate) -> MomentProject {
        let p = MomentProject(template: template)
        draft = p
        return p
    }

    func save(_ project: MomentProject) {
        project.touch()
        if let i = projects.firstIndex(where: { $0.id == project.id }) {
            projects[i] = project
        } else {
            projects.insert(project, at: 0)
        }
        draft = project
        persist()
    }

    func duplicate(_ project: MomentProject) -> MomentProject {
        let copy = ProjectDoc(project).project()
        copy.id = UUID(); copy.title = project.title + " copy"; copy.created = .now; copy.updated = .now
        projects.insert(copy, at: 0); draft = copy; persist()
        return copy
    }

    func remove(_ project: MomentProject) {
        projects.removeAll { $0.id == project.id }
        if draft?.id == project.id { draft = nil }
        persist()
    }

    // MARK: Folders

    func addFolder(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !folders.contains(n) else { return }
        folders.append(n); persistMeta()
    }
    func removeFolder(_ name: String) {
        folders.removeAll { $0 == name }
        for p in projects where p.folder == name { p.folder = nil }
        persist(); persistMeta()
    }
    func move(_ project: MomentProject, to folder: String?) {
        project.folder = folder; persist()
    }

    // MARK: Kits

    func saveKit(_ kit: MomentKit) { kits.insert(kit, at: 0); persistMeta() }
    func removeKit(_ kit: MomentKit) { kits.removeAll { $0.id == kit.id }; persistMeta() }

    // MARK: Ideas

    func addIdea(_ idea: MomentIdea) { ideas.insert(idea, at: 0); persistMeta() }
    func updateIdea(_ idea: MomentIdea) {
        if let i = ideas.firstIndex(where: { $0.id == idea.id }) { ideas[i] = idea; persistMeta() }
    }
    func removeIdea(_ idea: MomentIdea) { ideas.removeAll { $0.id == idea.id }; persistMeta() }

    // MARK: - On-device persistence (Application Support, never uploaded)

    private var base: URL {
        let b = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nu.moments", isDirectory: true)
        try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return b
    }
    private var storeURL: URL { base.appendingPathComponent("projects.json") }
    private var metaURL: URL { base.appendingPathComponent("library.json") }

    private struct Meta: Codable {
        var folders: [String] = []
        var kits: [MomentKit] = []
        var ideas: [MomentIdea] = []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects.map(ProjectDoc.init)) else { return }
        try? data.write(to: storeURL, options: [.atomic, .completeFileProtection])
    }
    private func persistMeta() {
        guard let data = try? JSONEncoder().encode(Meta(folders: folders, kits: kits, ideas: ideas)) else { return }
        try? data.write(to: metaURL, options: [.atomic, .completeFileProtection])
    }

    private func load() {
        if let data = try? Data(contentsOf: storeURL), let docs = try? JSONDecoder().decode([ProjectDoc].self, from: data) {
            projects = docs.map { $0.project() }
        }
        if let data = try? Data(contentsOf: metaURL), let meta = try? JSONDecoder().decode(Meta.self, from: data) {
            folders = meta.folders; kits = meta.kits; ideas = meta.ideas
        }
    }
}
