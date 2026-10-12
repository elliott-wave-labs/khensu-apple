// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(KhensuCoreBindings)
import CryptoKit
import Foundation
import KhensuCoreBindings

/// `KhensuCore` over khensu-core's UniFFI bindings (`KhensuClient`).
///
/// khensu-core owns the keys, MLS state, the outbox and the mix packets. This
/// actor adds what the core doesn't keep: message history, chat flags (pin,
/// mute, archive, unread), contact names and verification, and the network
/// link (QUIC to the entry node, tick and receive loops).
public actor RustCore: KhensuCore {
    public nonisolated let implementationName = "khensu-core (UniFFI)"

    /// App-side state, exported together with the core's sealed state.
    struct Side: Codable {
        var handle: Handle?
        var contacts: [Contact] = []
        var peers: [String: Address] = [:]
        var meta: [String: Meta] = [:]
        var messages: [String: [Message]] = [:]
    }

    struct Meta: Codable {
        var isPinned = false
        var isMuted = false
        var isArchived = false
        var unreadCount = 0
    }

    struct Export: Codable {
        var version = 1
        var key: Data
        var client: Data
        var side: Side
    }

    private var client: KhensuClient?
    private var side = Side()
    private var connection: ConnectionState = .offline
    private var subscribers: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]
    private var link: GatewayLink?
    private var session: LinkSession?
    private var loops: [Task<Void, Never>] = []
    private var testOptions = NetworkTestOptions.off

    public init() {
        _ = Self.logSinkInstalled
    }

    private static var nowMs: UInt64 { UInt64(Date.now.timeIntervalSince1970 * 1000) }

    /// Routes khensu-core's tracing events into `CoreLog`, once per process
    /// (`setLogSink` returns false when a sink is already installed).
    private static let logSinkInstalled: Bool = setLogSink(sink: CoreLogSink(), minLevel: .debug)

    private final class CoreLogSink: LogSink, Sendable {
        func log(level: KhensuCoreBindings.LogLevel, target: String, message: String, fields: String) {
            let l: KhensuKit.LogLevel = switch level {
            case .trace: .trace
            case .debug: .debug
            case .info: .info
            case .warn: .warn
            case .error: .error
            }
            CoreLog.shared.append(level: l, target: target, message: message, fields: fields)
        }
    }

    private func log(_ level: KhensuKit.LogLevel, _ message: String, _ fields: String = "") {
        CoreLog.shared.append(level: level, target: "RustCore", message: message, fields: fields)
    }

    private func requireClient() throws -> KhensuClient {
        guard let client else { throw KhensuError.noIdentity }
        return client
    }

    // MARK: Identity

    public func currentIdentity() -> Identity? {
        guard let info = client?.identity() else { return nil }
        return identity(from: info)
    }

    private func identity(from info: IdentityInfo) -> Identity? {
        guard let address = Self.address(info.address, hex: info.addressHex) else { return nil }
        return Identity(address: address, displayName: info.displayName, handle: side.handle,
                        identityKeys: [info.identityPublicKey], createdAt: .distantPast)
    }

    /// khensu-core creates its own ML-DSA-87 identity key and inception entry;
    /// `identityKey` (the Secure Enclave key) isn't part of the inception yet.
    public func createIdentity(displayName: String, handle: Handle?, identityKey: Data) throws -> NewIdentity {
        guard client == nil else { throw KhensuError.identityExists }
        let c = try wrap { try KhensuClient(displayName: displayName, nowMs: Self.nowMs) }
        client = c
        var pending = handle
        pending?.status = .pending
        side = Side(handle: pending)
        guard let identity = identity(from: c.identity()) else { throw KhensuError.invalidAddress }
        broadcast(.conversationsChanged)
        // The recovery kit lives in khensu-core and isn't exposed over FFI yet.
        return NewIdentity(identity: identity, recoveryPhrase: [])
    }

    public func updateProfile(displayName: String, handle: Handle?) throws -> Identity {
        side.handle = handle
        guard let identity = currentIdentity() else { throw KhensuError.noIdentity }
        return identity
    }

    // MARK: Contacts

    public func myInvite() throws -> ContactInvite {
        let c = try requireClient()
        guard let identity = currentIdentity() else { throw KhensuError.noIdentity }
        let card = try wrap { try c.createContactCard(nowMs: Self.nowMs) }
        return ContactInvite(address: identity.address, displayName: identity.displayName, handle: identity.handle,
                             keyFingerprint: ContactInvite.fingerprint(identity.identityKeys), card: card)
    }

    public func addContact(_ invite: ContactInvite) throws -> Conversation {
        let c = try requireClient()
        guard let card = invite.card else { throw KhensuError.core("This code has no contact card. Ask for their khensu.nu link.") }
        guard invite.address != currentIdentity()?.address else { throw KhensuError.invalidInvite }
        if let existing = side.peers.first(where: { $0.value == invite.address })?.key, let convo = conversation(existing) {
            return convo
        }
        let id = try wrap { try c.createDirectConversation(contactCard: card, nowMs: Self.nowMs) }
        if !side.contacts.contains(where: { $0.address == invite.address }) {
            // Until the core exposes contacts' identity keys, the invite's key
            // fingerprint stands in for them in safety numbers (both sides do the same).
            side.contacts.append(Contact(address: invite.address, displayName: invite.displayName, handle: invite.handle,
                                         identityKeys: [invite.keyFingerprint]))
        }
        side.peers[id] = invite.address
        side.meta[id] = Meta()
        broadcast(.conversationsChanged)
        guard let convo = conversation(id) else { throw KhensuError.unknownConversation }
        return convo
    }

    public func contact(_ address: Address) -> Contact? {
        side.contacts.first { $0.address == address }
    }

    public func safetyNumber(with address: Address) throws -> SafetyNumber {
        guard let me = currentIdentity() else { throw KhensuError.noIdentity }
        guard let them = contact(address) else { throw KhensuError.unknownConversation }
        return SafetyNumber.pair(mine: ([ContactInvite.fingerprint(me.identityKeys)], me.address), theirs: (them.identityKeys, them.address))
    }

    public func setVerified(_ verified: Bool, contact address: Address) throws {
        guard let i = side.contacts.firstIndex(where: { $0.address == address }) else { throw KhensuError.unknownConversation }
        side.contacts[i].verified = verified
        broadcast(.conversationsChanged)
    }

    // MARK: Conversations

    public func conversations() -> [Conversation] {
        guard let client else { return [] }
        return client.conversations().compactMap { conversation($0.conversationId, info: $0) }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.lastActivity > $1.lastActivity
            }
    }

    private func conversation(_ id: String, info: ConversationInfo? = nil) -> Conversation? {
        guard let info = info ?? client?.conversations().first(where: { $0.conversationId == id }),
              let raw = Data(hex: id)
        else { return nil }
        let peer = side.peers[id] ?? info.members.first(where: { !$0.isSelf }).flatMap { Self.address($0.address, hex: nil) }
        let peerContact = peer.flatMap(contact)
        let members = info.members.filter { !$0.isSelf }.compactMap { Self.address($0.address, hex: nil) }
        var c = Conversation(id: ConversationID(raw: raw), kind: info.direct ? .direct : .group,
                             title: info.direct ? (peerContact?.displayName ?? peer?.short ?? info.title) : info.title,
                             members: info.direct ? peer.map { [$0] } ?? members : members)
        let meta = side.meta[id] ?? Meta()
        c.isPinned = meta.isPinned
        c.isMuted = meta.isMuted
        c.isArchived = meta.isArchived
        c.unreadCount = meta.unreadCount
        c.isVerified = peerContact?.verified ?? false
        c.lastMessage = side.messages[id]?.last
        return c
    }

    public func messages(in conversation: ConversationID) throws -> [Message] {
        guard self.conversation(conversation.hex) != nil else { throw KhensuError.unknownConversation }
        return side.messages[conversation.hex, default: []]
    }

    public func update(_ conversation: ConversationID, _ change: ConversationChange) throws {
        let id = conversation.hex
        guard self.conversation(id) != nil else { throw KhensuError.unknownConversation }
        var m = side.meta[id] ?? Meta()
        switch change {
        case .pin(let on): m.isPinned = on
        case .mute(let on): m.isMuted = on
        case .archive(let on): m.isArchived = on
        case .markRead: m.unreadCount = 0
        case .markUnread: m.unreadCount = max(1, m.unreadCount)
        }
        side.meta[id] = m
        broadcast(.conversationsChanged)
    }

    public func search(_ query: String) -> [Message] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return side.messages.values.joined()
            .filter { $0.body.previewText.localizedStandardContains(q) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    // MARK: Send and receive

    public func send(_ message: OutgoingMessage, to conversation: ConversationID) throws -> Message {
        let c = try requireClient()
        guard case .text(let text) = message.body else {
            throw KhensuError.core("Photos need the bulk lane, which khensu-core doesn't expose yet.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KhensuError.emptyMessage }
        let id = conversation.hex
        let messageID = try wrap { try c.sendText(conversationId: id, text: text, nowMs: Self.nowMs) }
        let sent = Message(id: MessageID(raw: Data(hex: messageID) ?? .random(count: 16)), conversationID: conversation,
                           sender: .me, body: message.body, sentAt: .now, state: .queued)
        side.messages[id, default: []].append(sent)
        broadcast(.conversationsChanged)
        return sent
    }

    /// Records from the extension's queue: `[UInt16 ref length][payload_key_ref][payload]`.
    public func receive(sealed packets: [Data]) throws -> [Message] {
        let c = try requireClient()
        var out: [Message] = []
        for p in packets {
            guard p.count > 2 else { continue }
            let refLen = Int(p[p.startIndex]) << 8 | Int(p[p.startIndex + 1])
            guard p.count >= 2 + refLen else { continue }
            let ref = p.subdata(in: p.startIndex + 2 ..< p.startIndex + 2 + refLen)
            let payload = p.subdata(in: p.startIndex + 2 + refLen ..< p.endIndex)
            out += handle((try? c.processIncoming(payloadKeyRef: ref, payload: payload, nowMs: Self.nowMs)) ?? [])
        }
        return out
    }

    public static func queueRecord(payloadKeyRef: Data, payload: Data) -> Data {
        Data([UInt8(payloadKeyRef.count >> 8), UInt8(payloadKeyRef.count & 0xFF)]) + payloadKeyRef + payload
    }

    @discardableResult
    private func handle(_ events: [ClientEvent]) -> [Message] {
        var received: [Message] = []
        for e in events {
            switch e {
            case .messageReceived(let cid, let mid, let sender, _, let text, let sentAtMs):
                guard let raw = Data(hex: cid) else { continue }
                let from = Self.address(sender, hex: nil)
                let m = Message(id: MessageID(raw: Data(hex: mid) ?? .random(count: 16)), conversationID: ConversationID(raw: raw),
                                sender: from.map(Sender.contact) ?? .contact(try! Address(bytes: Data(count: 32))),
                                body: .text(text), sentAt: Date(timeIntervalSince1970: Double(sentAtMs) / 1000), state: .delivered)
                side.messages[cid, default: []].append(m)
                side.meta[cid, default: Meta()].unreadCount += 1
                received.append(m)
                broadcast(.messageReceived(m))
            case .conversationJoined(let cid, _, _):
                if side.meta[cid] == nil { side.meta[cid] = Meta() }
            case .membersChanged, .removedFromConversation:
                break
            case .loopReturned(let rtt, let hops):
                broadcast(.network(.loopReturned(rttMs: rtt, hops: Int(hops))))
            case .headerAccepted(let epoch, let nodes, let committee):
                broadcast(.network(.headerAccepted(epoch: epoch, nodes: Int(nodes), committee: Int(committee))))
            case .storeReceipt(let replica, let epoch, let valid):
                broadcast(.network(.storeReceipt(replica: replica, epoch: epoch, valid: valid)))
            }
        }
        let chatEvents = events.contains { e in
            switch e {
            case .loopReturned, .headerAccepted, .storeReceipt: false
            default: true
            }
        }
        if chatEvents { broadcast(.conversationsChanged) }
        return received
    }

    public func events() -> AsyncStream<CoreEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CoreEvent.self, bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func broadcast(_ event: CoreEvent) {
        for c in subscribers.values { c.yield(event) }
    }

    // MARK: Network

    public func connect(_ config: DevnetConfig) async throws -> ConnectionState {
        let c = try requireClient()
        disconnect()
        setConnection(.connecting)
        do {
            try c.loadDirectory(json: String(decoding: config.json, as: UTF8.self), gateway: nil)
            let gw = try c.gateway()
            let link = try GatewayLink(endpoint: gw.endpoint)
            self.link = link
            try await link.start()
            let exporter = try link.exporter(label: linkExporterLabel(), length: 64)
            let hs = try LinkHandshake(nodeKemPublicKey: gw.kemPublicKey, nodeSigPublicKey: gw.sigPublicKey,
                                       tlsExporter: exporter, networkEpoch: c.networkEpoch(nowMs: Self.nowMs))
            try await link.send(hs.hello())
            let acceptLength = try Self.length(of: await link.receive(exactly: 4))
            guard acceptLength == Int(linkAcceptLength()) else { throw KhensuError.core("Gateway sent a malformed handshake") }
            let session = try hs.finish(accept: try await link.receive(exactly: acceptLength))
            self.session = session
            try await link.send(session.sealSubscribe(deliveryId: c.deliveryId()))
            // Any epoch headers we missed while offline.
            try await sendControl(c.headerRequest())
            applyTestOptions(c)
            let interval = try c.tickIntervalMs()
            loops = [
                Task { await self.tickLoop(every: interval) },
                Task { await self.readLoop() },
            ]
            let status = c.networkStatus(nowMs: Self.nowMs)
            log(.info, "link.up", "gateway=\(gw.name) endpoint=\(gw.endpoint) epoch=\(status.epoch) header=\(status.headerEpoch) nodes=\(status.nodes)")
            setConnection(.connected(network: "\(config.name) via \(gw.name)", nodes: Int(status.nodes)))
        } catch {
            disconnect()
            let why = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
            log(.error, "link.failed", "error=\(why)")
            setConnection(.failed(why))
            throw KhensuError.core(why)
        }
        return connection
    }

    public func disconnect() {
        loops.forEach { $0.cancel() }
        loops = []
        link?.cancel()
        link = nil
        session = nil
        if connection != .offline {
            log(.info, "link.down")
            setConnection(.offline)
        }
    }

    public func connectionState() -> ConnectionState { connection }

    public func networkStatus() -> NetworkStatus? {
        guard let client else { return nil }
        let s = client.networkStatus(nowMs: Self.nowMs)
        guard !s.network.isEmpty else { return nil }
        return NetworkStatus(network: s.network, epoch: s.epoch, headerEpoch: s.headerEpoch, nextHeaderEpoch: s.nextHeaderEpoch,
                             nodes: Int(s.nodes), committee: Int(s.committee), mailboxReplicas: Int(s.mailboxReplicas), gateway: s.gateway,
                             ticks: s.ticks, pending: Int(s.pending), loopsSent: s.loopsSent, loopsReturned: s.loopsReturned,
                             lastLoopRTTMs: s.lastLoopRttMs, headersAccepted: s.headersAccepted,
                             storeReceiptsOK: s.storeReceiptsOk, storeReceiptsBad: s.storeReceiptsBad)
    }

    public func setNetworkTest(_ options: NetworkTestOptions) {
        testOptions = options
        if let client { applyTestOptions(client) }
    }

    private func applyTestOptions(_ c: KhensuClient) {
        c.setLoopRate(per100Ticks: testOptions.loopsPer100Ticks)
        c.setStoreReceipts(on: testOptions.storeReceipts)
        log(.info, "test.options", "loops_per_100_ticks=\(testOptions.loopsPer100Ticks) store_receipts=\(testOptions.storeReceipts)")
    }

    /// Writes one control message (one or more sealed frames) on the link.
    private func sendControl(_ message: Data) async throws {
        guard let link, let session else { return }
        for frame in try session.sealControl(message: message) {
            try await link.send(frame)
        }
    }

    private func setConnection(_ s: ConnectionState) {
        connection = s
        broadcast(.connection(s))
    }

    private static func length(of prefix: Data) throws -> Int {
        guard prefix.count == 4 else { throw KhensuError.core("Short length prefix") }
        return prefix.reduce(0) { $0 << 8 | Int($1) }
    }

    /// Sends one burst per tick (bulk, then small packets; cover where nothing is queued).
    private func tickLoop(every ms: UInt64) async {
        while !Task.isCancelled {
            do {
                guard let client, let session, let link else { return }
                let before = client.pendingOutgoing()
                for p in try client.tick(nowMs: Self.nowMs) {
                    try await link.send(session.sealPacket(packet: p.bytes))
                }
                if before > 0 && client.pendingOutgoing() < before { markSent() }
                try await Task.sleep(for: .milliseconds(Int(ms)))
            } catch is CancellationError {
                return
            } catch {
                fail(error)
                return
            }
        }
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                guard let link, let session, let client else { return }
                let prefix = try await link.receive(exactly: 4)
                let n = try Int(linkFrameLength(prefix: prefix))
                let frame = try session.openFrame(sealed: try await link.receive(exactly: n))
                switch frame {
                case .deliver(let ref, let payload):
                    handle(try client.processIncoming(payloadKeyRef: ref, payload: payload, nowMs: Self.nowMs))
                case .control(let message):
                    do {
                        handle(try client.processControl(message: message, nowMs: Self.nowMs))
                    } catch KhensuCoreBindings.KhensuError.Network(let msg) {
                        // A header more than one epoch ahead: ask for the chain from ours.
                        log(.warn, "header.gap", "error=\(msg)")
                        try await sendControl(client.headerRequest())
                    }
                case .packet, .subscribe, .padding, .controlPart:
                    break
                }
            } catch is CancellationError {
                return
            } catch {
                fail(error)
                return
            }
        }
    }

    private func fail(_ error: any Error) {
        guard !Task.isCancelled else { return }
        let why = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        disconnect()
        setConnection(.failed(why))
    }

    /// Outgoing messages that have left in a tick are Sent; Delivered needs receipts from the core.
    private func markSent() {
        guard let pending = client?.pendingOutgoing() else { return }
        for (cid, list) in side.messages {
            var queued = list.indices.filter { list[$0].isMine && (list[$0].state == .queued || list[$0].state == .sending) }
            queued.removeLast(min(Int(pending), queued.count))
            for i in queued {
                side.messages[cid]![i].state = .sent
                broadcast(.messageStateChanged(list[i].id, list[i].conversationID, .sent))
            }
        }
    }

    // MARK: State

    public func exportState() throws -> Data {
        let c = try requireClient()
        let key = Data.random(count: 32)
        let blob = try wrap { try c.exportState(key: key) }
        return try JSONEncoder().encode(Export(key: key, client: blob, side: side))
    }

    public func importState(_ data: Data) throws {
        guard let export = try? JSONDecoder().decode(Export.self, from: data) else { throw KhensuError.invalidState }
        client = try wrap { try KhensuClient.importState(blob: export.client, key: export.key) }
        side = export.side
        broadcast(.conversationsChanged)
    }

    public func wipe() {
        disconnect()
        client = nil
        side = Side()
        broadcast(.conversationsChanged)
    }

    // MARK: Helpers

    private static func address(_ text: String, hex: String?) -> Address? {
        if let a = try? Address(bech32m: text) { return a }
        if let raw = Data(hex: hex ?? text), let a = try? Address(bytes: raw) { return a }
        return nil
    }

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as KhensuError { throw e } catch {
            throw KhensuError.core((error as? any LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}
#endif
