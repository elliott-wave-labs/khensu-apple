// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network

/// The call relay (`tatenan relay`) for people who aren't on the same
/// network. It pairs connections by room ID and copies bytes; the call's
/// ML-KEM-1024 handshake and AES-256-GCM frames run end to end through it,
/// so the relay never sees media, names or keys.
enum CallRelay {
    /// `-KhensuRelay host[:port]` overrides it; `-KhensuRelayPlain YES` drops
    /// TLS for a local `tatenan relay --plain`.
    static var endpoint: NWEndpoint {
        let value = UserDefaults.standard.string(forKey: "KhensuRelay") ?? "relay.khensu.nu"
        let parts = value.split(separator: ":")
        let port = parts.count > 1 ? NWEndpoint.Port(String(parts[1])) ?? 443 : 443
        return .hostPort(host: .init(String(parts[0])), port: port)
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let p: NWParameters
        if UserDefaults.standard.bool(forKey: "KhensuRelayPlain") {
            p = NWParameters(tls: nil, tcp: tcp)
        } else {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "khensu-call/1")
            p = NWParameters(tls: tls, tcp: tcp)
        }
        p.serviceClass = .interactiveVideo
        return p
    }

    static func connection() -> NWConnection {
        NWConnection(to: endpoint, using: parameters())
    }

    static func join(_ room: String) -> Data { Data("JOIN \(room)\n".utf8) }
    static func accept(_ room: String, _ token: Substring) -> Data { Data("ACCEPT \(room) \(token)\n".utf8) }
}

/// The host's control connection to the relay: registers the room and,
/// for each guest the relay announces, hands back a connection that dials
/// in for that guest. Reconnects every few seconds while the call is open.
final class CallRelayHost: @unchecked Sendable {
    private let room: String
    private let queue = DispatchQueue(label: "nu.khensu.call.relay")
    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = false

    /// A connection for one guest and the header it must send first.
    var onGuest: (@Sendable (NWConnection, Data) -> Void)?
    /// Whether the room is registered on the relay right now.
    var onRegistered: (@Sendable (Bool) -> Void)?

    init(room: String) { self.room = room }

    func start() { queue.async { self.open() } }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
        }
    }

    private func open() {
        guard !stopped else { return }
        let c = CallRelay.connection()
        connection = c
        buffer = Data()
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                c.send(content: Data("HOST \(self.room)\n".utf8), completion: .idempotent)
                self.read(c)
            case .waiting: c.cancel()
            case .failed, .cancelled: self.retry(c)
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func retry(_ c: NWConnection) {
        guard c === connection else { return }
        connection = nil
        onRegistered?(false)
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 3) { self.open() }
    }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.lines()
            if done || error != nil { return c.cancel() }
            self.read(c)
        }
    }

    private func lines() {
        while let i = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...i)
            if line == "OK" {
                onRegistered?(true)
            } else if line == "BUSY" {
                stopped = true
                connection?.cancel()
            } else if line.hasPrefix("GUEST ") {
                let token = line.dropFirst(6)
                guard token.count == 32, token.allSatisfy(\.isHexDigit) else { continue }
                onGuest?(CallRelay.connection(), CallRelay.accept(room, token))
            }
        }
    }
}
