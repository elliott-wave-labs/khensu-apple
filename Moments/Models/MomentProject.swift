// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import UniformTypeIdentifiers

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

    init(id: UUID = UUID(), url: URL, duration: TimeInterval, isPhoto: Bool, inPoint: TimeInterval = 0, outDuration: TimeInterval? = nil) {
        self.id = id
        self.url = url
        self.duration = duration
        self.isPhoto = isPhoto
        self.inPoint = inPoint
        self.outDuration = outDuration ?? (isPhoto ? 2.4 : min(duration, 2.4))
    }

    private enum CodingKeys: String, CodingKey { case id, url, duration, isPhoto, inPoint, outDuration, speed, muted }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        isPhoto = try c.decode(Bool.self, forKey: .isPhoto)
        inPoint = try c.decodeIfPresent(TimeInterval.self, forKey: .inPoint) ?? 0
        outDuration = try c.decode(TimeInterval.self, forKey: .outDuration)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
}

struct MomentCaption: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var text: String
    var style: CaptionStyle
    var start: TimeInterval
    var duration: TimeInterval

    init(id: UUID = UUID(), text: String, style: CaptionStyle = .pop, start: TimeInterval = 0, duration: TimeInterval = 2.5) {
        self.id = id
        self.text = text
        self.style = style
        self.start = start
        self.duration = duration
    }
}

enum CaptionStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case pop, typewriter, soft, stamp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pop: "Pop"
        case .typewriter: "Typewriter"
        case .soft: "Soft"
        case .stamp: "Stamp"
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
    var musicVolume: Double = 0.8
    var beatMarks: [TimeInterval]
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
        self.beatMarks = []
        self.created = .now
        self.updated = .now
    }

    var totalDuration: TimeInterval {
        clips.reduce(0) { $0 + $1.outDuration }
    }

    func touch() { updated = .now }
}

@Observable
@MainActor
final class ProjectStore {
    var projects: [MomentProject] = []
    var draft: MomentProject?

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
        let p = MomentProject(template: project.template, title: project.title + " copy")
        p.clips = project.clips; p.captions = project.captions; p.musicURL = project.musicURL
        p.format = project.format; p.look = project.look; p.musicVolume = project.musicVolume; p.beatMarks = project.beatMarks
        projects.insert(p, at: 0); draft = p; persist()
        return p
    }

    func remove(_ project: MomentProject) {
        projects.removeAll { $0.id == project.id }
        if draft?.id == project.id { draft = nil }
        persist()
    }

    // MARK: - On-device persistence (Application Support, never uploaded)

    private struct Stored: Codable {
        var id: UUID; var title: String; var template: MomentTemplate
        var clips: [MomentClip]; var captions: [MomentCaption]
        var musicPath: String?; var beatMarks: [TimeInterval]
        var created: Date; var updated: Date
        var format: ProjectFormat = .portrait
        var look: MomentLook? = nil
        var musicVolume: Double = 0.8
        private enum CodingKeys: String, CodingKey { case id, title, template, clips, captions, musicPath, beatMarks, created, updated, format, look, musicVolume }
        init(id: UUID, title: String, template: MomentTemplate, clips: [MomentClip], captions: [MomentCaption], musicPath: String?, beatMarks: [TimeInterval], created: Date, updated: Date, format: ProjectFormat, look: MomentLook?, musicVolume: Double) {
            self.id = id; self.title = title; self.template = template; self.clips = clips; self.captions = captions
            self.musicPath = musicPath; self.beatMarks = beatMarks; self.created = created; self.updated = updated
            self.format = format; self.look = look; self.musicVolume = musicVolume
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
            template = try c.decode(MomentTemplate.self, forKey: .template)
            clips = try c.decode([MomentClip].self, forKey: .clips); captions = try c.decode([MomentCaption].self, forKey: .captions)
            musicPath = try c.decodeIfPresent(String.self, forKey: .musicPath)
            beatMarks = try c.decode([TimeInterval].self, forKey: .beatMarks)
            created = try c.decode(Date.self, forKey: .created); updated = try c.decode(Date.self, forKey: .updated)
            format = try c.decodeIfPresent(ProjectFormat.self, forKey: .format) ?? .portrait
            look = try c.decodeIfPresent(MomentLook.self, forKey: .look)
            musicVolume = try c.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.8
        }
    }

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nu.moments", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("projects.json")
    }

    private func persist() {
        let stored = projects.map { p in
            Stored(id: p.id, title: p.title, template: p.template, clips: p.clips,
                   captions: p.captions, musicPath: p.musicURL?.path, beatMarks: p.beatMarks,
                   created: p.created, updated: p.updated, format: p.format, look: p.look, musicVolume: p.musicVolume)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storeURL, options: [.atomic, .completeFileProtection])
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return }
        projects = stored.map { s in
            let p = MomentProject(template: s.template, title: s.title)
            p.id = s.id; p.clips = s.clips; p.captions = s.captions
            p.musicURL = s.musicPath.map { URL(fileURLWithPath: $0) }
            p.format = s.format; if let l = s.look { p.look = l }; p.musicVolume = s.musicVolume
            p.beatMarks = s.beatMarks; p.created = s.created; p.updated = s.updated
            return p
        }
    }
}
