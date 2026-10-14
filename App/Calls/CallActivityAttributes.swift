// SPDX-License-Identifier: AGPL-3.0-only

import ActivityKit
import Foundation

/// Live Activity for an ongoing call or live room. Duration is rendered from
/// `startedAt` with `Text(..., style: .timer)` so the Dynamic Island and Lock
/// Screen count without push updates.
struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var peerName: String
        var muted: Bool
        var cameraOff: Bool
        var remoteCameraOff: Bool
        var viewerCount: Int
        var safetyCode: String?
    }

    /// Wall-clock start of the connected phase; drives the live duration.
    var startedAt: Date
    var mode: String
    var localName: String
}
