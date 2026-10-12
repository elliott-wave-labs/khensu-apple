// SPDX-License-Identifier: AGPL-3.0-only

import Network
import Observation
import SwiftUI

/// Rooms being hosted on this network or nearby over peer-to-peer Wi-Fi.
@MainActor @Observable
final class NearbyRooms {
    struct Room: Identifiable, Hashable {
        let id: String
        let host: String
        let mode: CallSession.Mode
    }

    private(set) var rooms: [Room] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: CallService.type, domain: nil), using: CallService.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Room] = results.compactMap { r in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                var host = "Someone nearby"
                var mode = CallSession.Mode.call
                if case .bonjour(let txt) = r.metadata {
                    host = txt["n"] ?? host
                    mode = CallSession.Mode(rawValue: txt["m"] ?? "") ?? .call
                }
                return Room(id: name, host: host, mode: mode)
            }
            Task { @MainActor in self?.rooms = found.sorted { $0.host < $1.host } }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// Invitations travel in the end-to-end encrypted chat, as plain text the
/// other app turns into a Join button.
enum CallInvite {
    static let prefix = "khensucall:"

    static func text(room: String, mode: CallSession.Mode) -> String {
        let what = mode == .live ? "I’m live on khensu.ñü" : "Video call on khensu.ñü"
        return "\(what). Tap Join to come in.\n\(prefix)\(mode.rawValue):\(room)"
    }

    static func parse(_ text: String) -> (CallSession.Mode, String)? {
        guard let r = text.range(of: #"khensucall:(call|live):([a-z2-7]{16})"#, options: .regularExpression) else { return nil }
        let parts = text[r].dropFirst(prefix.count).split(separator: ":")
        guard parts.count == 2, let mode = CallSession.Mode(rawValue: String(parts[0])) else { return nil }
        return (mode, String(parts[1]))
    }
}

struct CallsView: View {
    @Environment(AppModel.self) private var model
    @State private var nearby = NearbyRooms()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { start(.call) } label: {
                        Label("New video call", systemImage: "video.fill")
                    }
                    Button { start(.live) } label: {
                        Label("Go live", systemImage: "dot.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("Calls and live rooms are end to end encrypted with ML-KEM-1024 and AES-256-GCM, and go straight between devices on the same network or nearby. Calls across the internet arrive with the relay network, through two relays run by different operators.")
                }
                Section("Nearby") {
                    if nearby.rooms.isEmpty {
                        Text("Nobody nearby is hosting right now.").foregroundStyle(.secondary)
                    }
                    ForEach(nearby.rooms) { room in
                        Button {
                            model.activeCall = CallSession(joining: room.id, mode: room.mode, name: model.callName)
                        } label: {
                            HStack {
                                Avatar(title: room.host, size: 36)
                                VStack(alignment: .leading) {
                                    Text(room.host)
                                    Text(room.mode == .live ? "Live now" : "Video call").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(room.mode == .live ? "Watch" : "Join").fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Calls")
            .task { nearby.start() }
            .onDisappear { nearby.stop() }
        }
    }

    private func start(_ mode: CallSession.Mode) {
        do { model.activeCall = try CallSession(hosting: mode, name: model.callName) } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
