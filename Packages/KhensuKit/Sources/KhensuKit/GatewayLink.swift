// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(KhensuCoreBindings)
import Foundation
import Network
import Security

/// One QUIC stream to the entry node (ALPN `h3`), carrying khensu-core's
/// length-prefixed link messages. TLS here is only the outer layer: the node
/// is authenticated by the inner post-quantum handshake (`LinkHandshake`),
/// which binds to this session through the TLS exporter, so the outer
/// certificate isn't checked.
final class GatewayLink: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "nu.khensu.gateway-link")

    init(endpoint: String) throws {
        guard let colon = endpoint.lastIndex(of: ":"),
              let port = NWEndpoint.Port(String(endpoint[endpoint.index(after: colon)...]))
        else { throw KhensuError.core("Bad gateway endpoint \(endpoint)") }
        let host = String(endpoint[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let quic = NWProtocolQUIC.Options(alpn: ["h3"])
        quic.direction = .bidirectional
        quic.idleTimeout = 60_000
        sec_protocol_options_set_verify_block(quic.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(quic: quic))
    }

    func start(timeout: Duration = .seconds(10)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitReady() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw KhensuError.core("Gateway didn't answer within \(timeout)")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func waitReady() async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { c.resume() }
                case .failed(let e): once.run { c.resume(throwing: e) }
                case .cancelled: once.run { c.resume(throwing: CancellationError()) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// RFC 8446 7.5 exporter of the outer TLS session.
    func exporter(label: Data, length: Int) throws -> Data {
        guard let meta = connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata else {
            throw KhensuError.core("No QUIC metadata")
        }
        let secret = label.withUnsafeBytes { raw in
            sec_protocol_metadata_create_secret(meta.securityProtocolMetadata, label.count,
                                                raw.bindMemory(to: CChar.self).baseAddress!, length)
        }
        guard let secret else { throw KhensuError.core("TLS exporter unavailable") }
        return Data(secret as DispatchData)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func receive(exactly count: Int) async throws -> Data {
        var out = Data()
        while out.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - out.count) { data, _, isComplete, error in
                    if let error { c.resume(throwing: error) }
                    else if let data, !data.isEmpty { c.resume(returning: data) }
                    else if isComplete { c.resume(throwing: KhensuError.core("Gateway closed the stream")) }
                    else { c.resume(returning: Data()) }
                }
            }
            out.append(chunk)
        }
        return out
    }

    func cancel() { connection.cancel() }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.withLock {
            guard !done else { return }
            done = true
            body()
        }
    }
}
#endif
