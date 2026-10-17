// SPDX-License-Identifier: AGPL-3.0-only
// Apple SharePlay (GroupActivities) coordinator for ñü.ŵævẽš (`nu.khensu.waves`).
// Synchronizes track playback, Apple Speech word-pop lyrics, room acoustics, and real-time 3D
// spacetime bubble™ stem movements across FaceTime and iMessage participants.

import Foundation
#if canImport(GroupActivities)
import GroupActivities
#endif

struct WavesListenActivity: Codable, Hashable {
    var trackId: String
    var title: String
    var artist: String
    var url: String
}

#if canImport(GroupActivities)
@available(iOS 15.0, macOS 12.0, *)
extension WavesListenActivity: GroupActivity {
    static let activityIdentifier = "nu.khensu.waves.listen"

    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = title.isEmpty ? "ñü.ŵævẽš · 3D Spatial Audio" : title
        meta.subtitle = artist.isEmpty ? "spacetime bubble™ · khėnsu.ñü" : "\(artist) · spacetime bubble™"
        meta.type = .listenTogether
        if let u = URL(string: url) {
            meta.fallbackURL = u
        }
        return meta
    }
}
#endif

@MainActor
final class WavesSharePlayCoordinator {
    static let shared = WavesSharePlayCoordinator()

    var onEventToWeb: ((String) -> Void)?

    #if canImport(GroupActivities)
    private var session: GroupSession<WavesListenActivity>?
    private var messenger: GroupSessionMessenger?
    private var tasks = Set<Task<Void, Never>>()
    #endif

    private init() {
        #if canImport(GroupActivities)
        let t = Task {
            for await newSession in WavesListenActivity.sessions() {
                await self.configure(session: newSession)
            }
        }
        tasks.insert(t)
        #endif
    }

    func handleWebMessage(_ body: [String: Any]) async {
        let action = body["action"] as? String ?? "start"
        switch action {
        case "start":
            let trackId = body["trackId"] as? String ?? "first-attempt"
            let title = body["title"] as? String ?? "First Attempt"
            let artist = body["artist"] as? String ?? "nu.aura"
            let url = body["url"] as? String ?? "https://waves.khensu.nu/#/t/\(trackId)"
            await startActivity(trackId: trackId, title: title, artist: artist, url: url)
        case "sync":
            if let payload = body["payload"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                await sendPayload(json)
            }
        case "leave":
            leaveSession()
        default:
            break
        }
    }

    private func startActivity(trackId: String, title: String, artist: String, url: String) async {
        #if canImport(GroupActivities)
        let activity = WavesListenActivity(trackId: trackId, title: title, artist: artist, url: url)
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            _ = try? await activity.activate()
        case .activationDisabled, .cancelled:
            break
        @unknown default:
            break
        }
        #endif
    }

    private func sendPayload(_ json: String) async {
        #if canImport(GroupActivities)
        guard let messenger else { return }
        try? await messenger.send(json)
        #endif
    }

    private func leaveSession() {
        #if canImport(GroupActivities)
        session?.leave()
        session = nil
        messenger = nil
        #endif
    }

    #if canImport(GroupActivities)
    private func configure(session: GroupSession<WavesListenActivity>) async {
        self.session = session
        let messenger = GroupSessionMessenger(session: session)
        self.messenger = messenger

        let receiveTask = Task {
            for await (json, _) in messenger.messages(of: String.self) {
                await MainActor.run {
                    self.onEventToWeb?(json)
                }
            }
        }
        tasks.insert(receiveTask)

        session.join()
        if let initData = try? JSONSerialization.data(withJSONObject: [
            "type": "joined",
            "trackId": session.activity.trackId,
            "url": session.activity.url,
        ]), let initJson = String(data: initData, encoding: .utf8) {
            onEventToWeb?(initJson)
        }
    }
    #endif
}
