// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Main-actor-free copy of what the renderer needs.
struct ExportSnapshot: Sendable {
    let id: UUID
    let title: String
    let clips: [MomentClip]
    let captions: [MomentCaption]
    let musicURL: URL?
    let format: ProjectFormat
    let look: MomentLook
    let transition: MomentTransition
    let musicVolume: Double
    let accentR: Double; let accentG: Double; let accentB: Double
    let overlays: [MomentOverlay]
    let effects: [MomentEffect]
    let layout: CollageLayout
    let captionLook: CaptionLook
    let voiceoverURL: URL?
    let voiceoverVolume: Double
    let export: ExportSettings
    let backdropHex: String

    @MainActor
    init(project: MomentProject) {
        id = project.id
        title = project.title
        clips = project.clips
        captions = project.captions
        musicURL = project.musicURL
        format = project.format
        look = project.look
        transition = project.transition
        musicVolume = project.musicVolume
        accentR = project.template.accentR; accentG = project.template.accentG; accentB = project.template.accentB
        overlays = project.overlays
        effects = project.effects
        layout = project.layout
        captionLook = project.captionLook
        voiceoverURL = project.voiceoverURL
        voiceoverVolume = project.voiceoverVolume
        export = project.export
        backdropHex = project.backdropHex
    }

    /// The same project with different clips (one carousel slide, one preview group).
    func with(clips: [MomentClip], layout: CollageLayout? = nil, format: ProjectFormat? = nil, keepAudio: Bool = true) -> ExportSnapshot {
        ExportSnapshot(copy: self, clips: clips, layout: layout ?? self.layout, format: format ?? self.format, keepAudio: keepAudio)
    }

    private init(copy s: ExportSnapshot, clips: [MomentClip], layout: CollageLayout, format: ProjectFormat, keepAudio: Bool) {
        id = s.id; title = s.title; self.clips = clips; captions = keepAudio ? s.captions : []
        musicURL = keepAudio ? s.musicURL : nil; self.format = format; look = s.look; transition = s.transition
        musicVolume = s.musicVolume; accentR = s.accentR; accentG = s.accentG; accentB = s.accentB
        overlays = keepAudio ? s.overlays : s.overlays.filter { $0.kind != .media }
        effects = s.effects.filter(\.wholeTimeline) + (keepAudio ? s.effects.filter { !$0.wholeTimeline } : [])
        self.layout = layout; captionLook = s.captionLook
        voiceoverURL = keepAudio ? s.voiceoverURL : nil; voiceoverVolume = s.voiceoverVolume
        export = s.export; backdropHex = s.backdropHex
    }
}
