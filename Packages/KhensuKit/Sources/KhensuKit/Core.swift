// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The app's single entry point into khensu: identity, conversations, sending,
/// receiving and state export. `RustCore` implements it over khensu-core's
/// UniFFI bindings; `MockCore` implements it in memory for previews and tests.
///
/// Implementations are actors (or otherwise thread-safe); every call may hop.
public protocol KhensuCore: AnyObject, Sendable {
    /// Short name shown in Settings › About ("mock", "khensu-core 0.1.0").
    var implementationName: String { get }

    // MARK: Identity
    func currentIdentity() async -> Identity?
    /// Builds the inception event from the device's identity key (created by
    /// `DeviceVault`) and a fresh recovery key, and derives the address. The
    /// handle stays `.pending` until key transparency can register it.
    func createIdentity(displayName: String, handle: Handle?, identityKey: Data) async throws -> NewIdentity
    func updateProfile(displayName: String, handle: Handle?) async throws -> Identity

    // MARK: Contacts
    func myInvite() async throws -> ContactInvite
    func addContact(_ invite: ContactInvite) async throws -> Conversation
    func contact(_ address: Address) async -> Contact?
    func safetyNumber(with address: Address) async throws -> SafetyNumber
    func setVerified(_ verified: Bool, contact address: Address) async throws

    // MARK: Conversations
    func conversations() async throws -> [Conversation]
    func messages(in conversation: ConversationID) async throws -> [Message]
    func update(_ conversation: ConversationID, _ change: ConversationChange) async throws
    func search(_ query: String) async throws -> [Message]

    // MARK: Send and receive
    /// Seals and queues a message. The returned message starts `.queued` and
    /// advances through `events`.
    func send(_ message: OutgoingMessage, to conversation: ConversationID) async throws -> Message
    /// Processes sealed packets (from the network or the extension's incoming queue)
    /// and returns the messages they produced.
    func receive(sealed packets: [Data]) async throws -> [Message]
    /// Changes the core pushes to the UI: new messages, state changes, connection.
    func events() async -> AsyncStream<CoreEvent>

    // MARK: Network
    func connect(_ config: DevnetConfig) async throws -> ConnectionState
    func disconnect() async
    func connectionState() async -> ConnectionState
    /// Counters for the Network test screen; nil without a directory.
    func networkStatus() async -> NetworkStatus?
    /// Turns loop probes and store receipts on or off; applies to the current and later connections.
    func setNetworkTest(_ options: NetworkTestOptions) async

    // MARK: State
    /// Serialized local state, encrypted by the caller with the local store key.
    func exportState() async throws -> Data
    func importState(_ data: Data) async throws
    /// Crypto-erase: forget every key and message held by the core.
    func wipe() async
}

public struct NewIdentity: Sendable {
    public let identity: Identity
    /// The 24-word recovery kit, shown once during sign-up and never stored.
    public let recoveryPhrase: [String]

    public init(identity: Identity, recoveryPhrase: [String]) {
        self.identity = identity
        self.recoveryPhrase = recoveryPhrase
    }
}

public enum CoreEvent: Sendable, Equatable {
    case messageReceived(Message)
    case messageStateChanged(MessageID, ConversationID, DeliveryState)
    case conversationsChanged
    case connection(ConnectionState)
    /// Loops, headers and receipts, for the Network test screen.
    case network(NetworkEvent)
}

public struct SafetyNumber: Sendable, Hashable {
    /// Six groups of five digits.
    public let groups: [String]
    /// Four words, for checking out loud.
    public let checkPhrase: [String]
    /// QR payload combining both sides' hashes so either phone can scan the other.
    public let qrPayload: String

    public init(groups: [String], checkPhrase: [String], qrPayload: String) {
        self.groups = groups
        self.checkPhrase = checkPhrase
        self.qrPayload = qrPayload
    }

    /// Combined number for a pair: the two accounts' numbers, lower first.
    public static func pair(mine: (keys: [Data], address: Address), theirs: (keys: [Data], address: Address)) -> SafetyNumber {
        let a = IdentityCrypto.safetyNumber(identityKeys: mine.keys, address: mine.address)
        let b = IdentityCrypto.safetyNumber(identityKeys: theirs.keys, address: theirs.address)
        let (first, second) = a.joined() < b.joined() ? (a, b) : (b, a)
        let groups = (0..<6).map { i in i < 3 ? first[i] : second[i - 3] }
        let phrase = IdentityCrypto.checkPhrase(identityKeys: theirs.keys, address: theirs.address)
        return SafetyNumber(
            groups: groups,
            checkPhrase: phrase,
            qrPayload: "khensu-verify:1:" + (first + second).joined()
        )
    }
}
