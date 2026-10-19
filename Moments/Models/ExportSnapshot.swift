// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Main-actor-free copy of what export needs.
struct ExportSnapshot: Sendable {
    let id: UUID
    let title: String
    let clips: [MomentClip]
    let musicURL: URL?

    @MainActor
    init(project: MomentProject) {
        id = project.id
        title = project.title
        clips = project.clips
        musicURL = project.musicURL
    }
}
