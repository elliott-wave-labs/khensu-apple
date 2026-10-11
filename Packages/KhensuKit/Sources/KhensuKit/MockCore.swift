// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

/// In-memory `KhensuCore` for previews, tests and running the UI before
/// khensu-core's bindings exist. Identity derivation is real (ML-DSA-87 keys,
/// SHA3-256 address, recovery phrase); messaging is simulated: sent messages
/// advance through the delivery states on a timer and seeded contacts reply.
public actor MockCore: KhensuCore {
    public nonisolated let implementationName = "MockCore (simulated network)"

    public struct Timing: Sendable {
        public var stateStep: Duration
        public var replyDelay: Duration?
        public var recoveryIterations: UInt32

        public init(stateStep: Duration, replyDelay: Duration?, recoveryIterations: UInt32) {
            self.stateStep = stateStep
            self.replyDelay = replyDelay
            self.recoveryIterations = recoveryIterations
        }

        public static let interactive = Timing(stateStep: .milliseconds(600), replyDelay: .seconds(3), recoveryIterations: 1 << 20)
        public static let instant = Timing(stateStep: .zero, replyDelay: nil, recoveryIterations: 1 << 10)
    }

    struct Snapshot: Codable {
        var identity: Identity?
        var contacts: [Contact]
        var conversations: [Conversation]
        var messages: [ConversationID: [Message]]
    }

    /// Mock wire format for `receive(sealed:)`; RustCore receives real Outfox payloads.
    public struct MockPacket: Codable, Sendable {
        public var from: Address
        public var text: String
        public init(from: Address, text: String) {
            self.from = from
            self.text = text
        }
    }

    private var state = Snapshot(identity: nil, contacts: [], conversations: [], messages: [:])
    private var connection: ConnectionState = .offline
    private var subscribers: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]
    private let timing: Timing

    public init(timing: Timing = .interactive) {
        self.timing = timing
    }

    /// A core with an identity and sample chats, for previews and screenshots.
    public static func seeded(timing: Timing = .interactive) async -> MockCore {
        let core = MockCore(timing: timing)
        await core.seed()
        return core
    }

    // MARK: Identity

    public func currentIdentity() -> Identity? { state.identity }

    public func createIdentity(displayName: String, handle: Handle?, identityKey: Data) throws -> NewIdentity {
        guard state.identity == nil else { throw KhensuError.identityExists }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = IdentityCrypto.recoveryPhrase(entropy: .random(count: 32))
        let seed = IdentityCrypto.recoverySeed(phrase: phrase, iterations: timing.recoveryIterations)
        let recovery = try IdentityCrypto.recoveryKey(seed: seed)
        let inception = IdentityCrypto.inceptionBytes(
            identityKeys: [identityKey],
            nextKeyCommitment: IdentityCrypto.nextKeyCommitment(recoveryPublicKey: recovery.publicKey.rawRepresentation)
        )
        var pending = handle
        pending?.status = .pending
        let identity = Identity(
            address: IdentityCrypto.address(inception: inception),
            displayName: name.isEmpty ? "Me" : name,
            handle: pending,
            identityKeys: [identityKey],
            createdAt: .now
        )
        state.identity = identity
        let notes = Conversation(id: .random(), kind: .notes, title: "Saved Messages", members: [identity.address])
        state.conversations.append(notes)
        broadcast(.conversationsChanged)
        return NewIdentity(identity: identity, recoveryPhrase: phrase)
    }

    public func updateProfile(displayName: String, handle: Handle?) throws -> Identity {
        guard var identity = state.identity else { throw KhensuError.noIdentity }
        identity.displayName = displayName
        identity.handle = handle
        state.identity = identity
        return identity
    }

    // MARK: Contacts

    public func myInvite() throws -> ContactInvite {
        guard let identity = state.identity else { throw KhensuError.noIdentity }
        return ContactInvite(identity: identity)
    }

    public func addContact(_ invite: ContactInvite) throws -> Conversation {
        guard let me = state.identity else { throw KhensuError.noIdentity }
        guard invite.address != me.address else { throw KhensuError.invalidInvite }
        if let existing = state.conversations.first(where: { $0.kind == .direct && $0.members == [invite.address] }) {
            return existing
        }
        // The mock invents the contact's keys; RustCore fetches them and checks the fingerprint.
        let contact = Contact(
            address: invite.address,
            displayName: invite.displayName,
            handle: invite.handle,
            identityKeys: [Data(SHA512.hash(data: invite.address.bytes + invite.keyFingerprint))]
        )
        state.contacts.append(contact)
        let conversation = Conversation(id: .random(), kind: .direct, title: contact.displayName, members: [contact.address])
        state.conversations.append(conversation)
        broadcast(.conversationsChanged)
        return conversation
    }

    public func contact(_ address: Address) -> Contact? {
        state.contacts.first { $0.address == address }
    }

    public func safetyNumber(with address: Address) throws -> SafetyNumber {
        guard let me = state.identity else { throw KhensuError.noIdentity }
        guard let them = contact(address) else { throw KhensuError.unknownConversation }
        return SafetyNumber.pair(mine: (me.identityKeys, me.address), theirs: (them.identityKeys, them.address))
    }

    public func setVerified(_ verified: Bool, contact address: Address) throws {
        guard let i = state.contacts.firstIndex(where: { $0.address == address }) else { throw KhensuError.unknownConversation }
        state.contacts[i].verified = verified
        for j in state.conversations.indices where state.conversations[j].kind == .direct && state.conversations[j].members == [address] {
            state.conversations[j].isVerified = verified
        }
        broadcast(.conversationsChanged)
    }

    // MARK: Conversations

    public func conversations() -> [Conversation] {
        state.conversations.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.lastActivity > $1.lastActivity
        }
    }

    public func messages(in conversation: ConversationID) throws -> [Message] {
        guard state.conversations.contains(where: { $0.id == conversation }) else { throw KhensuError.unknownConversation }
        return state.messages[conversation, default: []]
    }

    public func update(_ conversation: ConversationID, _ change: ConversationChange) throws {
        guard let i = state.conversations.firstIndex(where: { $0.id == conversation }) else { throw KhensuError.unknownConversation }
        switch change {
        case .pin(let on): state.conversations[i].isPinned = on
        case .mute(let on): state.conversations[i].isMuted = on
        case .archive(let on): state.conversations[i].isArchived = on
        case .markRead: state.conversations[i].unreadCount = 0
        case .markUnread: state.conversations[i].unreadCount = max(1, state.conversations[i].unreadCount)
        }
        broadcast(.conversationsChanged)
    }

    public func search(_ query: String) -> [Message] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return state.messages.values.joined()
            .filter { $0.body.previewText.localizedStandardContains(q) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    // MARK: Send and receive

    public func send(_ message: OutgoingMessage, to conversation: ConversationID) throws -> Message {
        guard state.identity != nil else { throw KhensuError.noIdentity }
        guard let i = state.conversations.firstIndex(where: { $0.id == conversation }) else { throw KhensuError.unknownConversation }
        if case .text(let t) = message.body, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw KhensuError.emptyMessage
        }
        let isNotes = state.conversations[i].kind == .notes
        let sent = Message(id: .random(), conversationID: conversation, sender: .me, body: message.body, sentAt: .now, state: isNotes ? .read : .queued)
        append(sent)
        if !isNotes {
            let members = state.conversations[i].members
            Task { await self.simulateDelivery(of: sent.id, in: conversation, replyFrom: members.first) }
        }
        return sent
    }

    public func receive(sealed packets: [Data]) throws -> [Message] {
        var out: [Message] = []
        for p in packets {
            guard let packet = try? JSONDecoder().decode(MockPacket.self, from: p) else { continue }
            guard let conversation = state.conversations.first(where: { $0.kind == .direct && $0.members == [packet.from] }) else { continue }
            let m = Message(id: .random(), conversationID: conversation.id, sender: .contact(packet.from), body: .text(packet.text), sentAt: .now, state: .delivered)
            append(m)
            out.append(m)
        }
        return out
    }

    public func events() -> AsyncStream<CoreEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CoreEvent.self, bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    // MARK: Network

    public func connect(_ config: DevnetConfig) async throws -> ConnectionState {
        connection = .connecting
        broadcast(.connection(connection))
        if timing.stateStep > .zero { try await Task.sleep(for: timing.stateStep) }
        connection = .connected(network: "\(config.name) (simulated)", nodes: config.endpoints.count)
        broadcast(.connection(connection))
        return connection
    }

    public func disconnect() {
        connection = .offline
        broadcast(.connection(connection))
    }

    public func connectionState() -> ConnectionState { connection }

    // MARK: State

    public func exportState() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(state)
    }

    public func importState(_ data: Data) throws {
        do { state = try JSONDecoder().decode(Snapshot.self, from: data) } catch { throw KhensuError.invalidState }
        broadcast(.conversationsChanged)
    }

    public func wipe() {
        state = Snapshot(identity: nil, contacts: [], conversations: [], messages: [:])
        connection = .offline
        broadcast(.conversationsChanged)
    }

    // MARK: Private

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func broadcast(_ event: CoreEvent) {
        for c in subscribers.values { c.yield(event) }
    }

    private func append(_ message: Message) {
        state.messages[message.conversationID, default: []].append(message)
        if let i = state.conversations.firstIndex(where: { $0.id == message.conversationID }) {
            state.conversations[i].lastMessage = message
            if !message.isMine { state.conversations[i].unreadCount += 1 }
        }
        if !message.isMine { broadcast(.messageReceived(message)) }
        broadcast(.conversationsChanged)
    }

    private func setState(_ s: DeliveryState, of id: MessageID, in conversation: ConversationID) {
        guard let j = state.messages[conversation]?.firstIndex(where: { $0.id == id }) else { return }
        state.messages[conversation]![j].state = s
        if let i = state.conversations.firstIndex(where: { $0.id == conversation }), state.conversations[i].lastMessage?.id == id {
            state.conversations[i].lastMessage?.state = s
        }
        broadcast(.messageStateChanged(id, conversation, s))
    }

    private func simulateDelivery(of id: MessageID, in conversation: ConversationID, replyFrom: Address?) async {
        for s in [DeliveryState.sending, .sent, .delivered] {
            if timing.stateStep > .zero { try? await Task.sleep(for: timing.stateStep) }
            setState(s, of: id, in: conversation)
        }
        guard let delay = timing.replyDelay, let from = replyFrom, contact(from) != nil else { return }
        try? await Task.sleep(for: delay)
        setState(.read, of: id, in: conversation)
        let replies = ["Got it.", "Seen. The mixnet took its time, as promised.", "🌙", "Let's talk on a call later?", "Received, safety number checks out."]
        _ = try? receive(sealed: [JSONEncoder().encode(MockPacket(from: from, text: replies.randomElement()!))])
    }

    private func seed() {
        let key = (try? MLDSA87.PrivateKey())?.publicKey.rawRepresentation ?? Data(count: 2592)
        guard (try? createIdentity(displayName: "Elliott", handle: try? Handle("elliott"), identityKey: key)) != nil else { return }
        func person(_ name: String, _ handle: String?) -> Contact {
            let address = try! Address(bytes: Data(SHA256.hash(data: Data(name.utf8))))
            return Contact(address: address, displayName: name, handle: handle.flatMap { try? Handle($0, status: .claimed) },
                           identityKeys: [Data(SHA512.hash(data: Data("key \(name)".utf8)))])
        }
        let ana = person("Ana Ferreira", "ana")
        let ra = person("Ramses", "ramses")
        let nef = person("Nefertari Lab", nil)
        let tho = person("Thoth", "thoth")
        state.contacts = [ana, ra, nef, tho]
        state.contacts[0].verified = true

        let now = Date.now
        func convo(_ kind: ConversationKind, _ title: String, _ members: [Contact], _ lines: [(Sender, String, TimeInterval)], unread: Int = 0, pinned: Bool = false, muted: Bool = false, verified: Bool = false, timer: UInt32 = 0) {
            var c = Conversation(id: .random(), kind: kind, title: title, members: members.map(\.address))
            c.isPinned = pinned
            c.isMuted = muted
            c.isVerified = verified
            c.disappearingAfter = timer
            let msgs = lines.map { Message(id: .random(), conversationID: c.id, sender: $0.0, body: .text($0.1), sentAt: now.addingTimeInterval(-$0.2), state: .read) }
            c.lastMessage = msgs.last
            c.unreadCount = unread
            state.conversations.append(c)
            state.messages[c.id] = msgs
        }
        convo(.direct, ana.displayName, [ana], [
            (.contact(ana.address), "Did the new build land on your phone?", 3600),
            (.me, "Installing it now. Safety number matched, by the way.", 3500),
            (.contact(ana.address), "Good. Lisbon trip moved to 12–19 May.", 420),
            (.contact(ana.address), "Bring the shield, the hostel Wi-Fi is hopeless.", 300),
        ], unread: 2, pinned: true, verified: true, timer: 86_400)
        convo(.group, "Night Sky Club", [ana, ra, tho], [
            (.contact(ra.address), "Waning crescent tonight, 23% lit.", 7200),
            (.contact(tho.address), "Clear skies from 22:00. Who's in?", 5400),
            (.me, "In. Bringing the tripod.", 5000),
        ], unread: 5)
        convo(.direct, ra.displayName, [ra], [
            (.me, "Sent you the node schedule.", 90_000),
            (.contact(ra.address), "Thanks, the Pi is staking now.", 86_000),
        ], muted: true)
        convo(.channel, "khensu.nu updates", [nef], [
            (.contact(nef.address), "Devnet is up: mixnet, mailboxes and push gateway on one machine.", 172_000),
        ], unread: 1)
        convo(.direct, tho.displayName, [tho], [
            (.contact(tho.address), "Four-word check: does yours say the same?", 260_000),
        ])
        if let i = state.conversations.firstIndex(where: { $0.kind == .notes }) {
            let m = Message(id: .random(), conversationID: state.conversations[i].id, sender: .me, body: .text("Recovery kit printed and stored."), sentAt: now.addingTimeInterval(-400_000), state: .read)
            state.messages[state.conversations[i].id] = [m]
            state.conversations[i].lastMessage = m
        }
    }
}
