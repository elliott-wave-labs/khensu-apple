// SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import ActivityKit
import Foundation

/// Starts, updates and ends the call Live Activity (Dynamic Island + Lock Screen).
@MainActor
enum CallLiveActivity {
    static func start(for session: CallSession) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let started = session.connectedAt ?? .now
        let attributes = CallActivityAttributes(
            startedAt: started,
            mode: session.mode.rawValue,
            localName: session.localName
        )
        let state = state(for: session)
        // End any stale call activities before starting a new one.
        for activity in Activity<CallActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        let content = ActivityContent(state: state, staleDate: nil)
        _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    static func update(for session: CallSession) {
        let state = state(for: session)
        let content = ActivityContent(state: state, staleDate: nil)
        for activity in Activity<CallActivityAttributes>.activities {
            Task { await activity.update(content) }
        }
    }

    static func end() {
        for activity in Activity<CallActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private static func state(for session: CallSession) -> CallActivityAttributes.ContentState {
        let peer = session.peers.first
        let name: String = {
            if session.mode == .live && session.role == .host { return session.localName }
            return peer?.name ?? (session.role == .host ? "Waiting" : "khensu.ñü")
        }()
        return CallActivityAttributes.ContentState(
            peerName: name,
            muted: session.muted,
            cameraOff: session.cameraOff,
            remoteCameraOff: peer?.cameraOff ?? false,
            viewerCount: session.viewerCount,
            safetyCode: session.safetyCode
        )
    }
}
#endif
