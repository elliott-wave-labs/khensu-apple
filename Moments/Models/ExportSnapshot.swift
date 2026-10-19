// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Main-actor-free copy of what export needs.
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

    @MainActor
    init(project: MomentProject) {
        id = project.id
        title = project.title
        clips = project.clips
        captions = project.captions
        musicURL = project.musicURL
        format = project.format
        look = project.look
        transition = project.template.transition
        musicVolume = project.musicVolume
        accentR = project.template.accentR; accentG = project.template.accentG; accentB = project.template.accentB
    }
}
