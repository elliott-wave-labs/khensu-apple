// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A permanent khensu address: SHA3-256 of the inception event (PROTOCOL.md 3.1).
public struct Address: Hashable, Sendable, Codable {
    public let bytes: Data

    public init(bytes: Data) throws(KhensuError) {
        guard bytes.count == 32 else { throw .invalidAddress }
        self.bytes = bytes
    }

    public init(bech32m string: String) throws(KhensuError) {
        guard let decoded = Bech32m.decode(string), decoded.hrp == Bech32m.khensuHRP else {
            throw .invalidAddress
        }
        try self.init(bytes: decoded.data)
    }

    /// `khensu1...`
    public var bech32m: String { Bech32m.encode(hrp: Bech32m.khensuHRP, data: bytes) }

    /// Shortened form for compact UI: `khensu1qx8f…k3zr`.
    public var short: String {
        let full = bech32m
        guard full.count > 18 else { return full }
        return "\(full.prefix(11))…\(full.suffix(4))"
    }
}

public enum HandleStatus: String, Sendable, Codable {
    /// Chosen on the device; the key transparency log isn't live yet.
    case pending
    case claimed
}

public struct Handle: Hashable, Sendable, Codable {
    public let name: String
    public var status: HandleStatus

    public init(_ raw: String, status: HandleStatus = .pending) throws(KhensuError) {
        self.name = try Handle.normalize(raw)
        self.status = status
    }

    /// `name.khensu.nu`
    public var domain: String { "\(name).khensu.nu" }
    public var at: String { "@\(name)" }

    /// PROTOCOL.md 3.5: NFKC-casefold, then `[a-z0-9_]{3,32}`.
    public static func normalize(_ raw: String) throws(KhensuError) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("@") { s.removeFirst() }
        if s.lowercased().hasSuffix(".khensu.nu") { s.removeLast(".khensu.nu".count) }
        let folded = s.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: nil)
            .lowercased()
        guard (3...32).contains(folded.count),
              folded.unicodeScalars.allSatisfy({ allowedHandleScalars.contains($0) })
        else { throw .invalidHandle }
        return folded
    }

    private static let allowedHandleScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
}

public struct Identity: Hashable, Sendable, Codable {
    public let address: Address
    public var displayName: String
    public var handle: Handle?
    /// Identity public keys (ML-DSA-87 in RustCore, placeholder bytes in MockCore).
    public let identityKeys: [Data]
    public let createdAt: Date

    public init(address: Address, displayName: String, handle: Handle?, identityKeys: [Data], createdAt: Date) {
        self.address = address
        self.displayName = displayName
        self.handle = handle
        self.identityKeys = identityKeys
        self.createdAt = createdAt
    }
}

public struct Contact: Hashable, Sendable, Codable, Identifiable {
    public var id: Address { address }
    public let address: Address
    public var displayName: String
    public var handle: Handle?
    public var identityKeys: [Data]
    public var verified: Bool

    public init(address: Address, displayName: String, handle: Handle?, identityKeys: [Data], verified: Bool = false) {
        self.address = address
        self.displayName = displayName
        self.handle = handle
        self.identityKeys = identityKeys
        self.verified = verified
    }
}

public struct ConversationID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: Data
    public init(raw: Data) { self.raw = raw }
    public static func random() -> ConversationID { ConversationID(raw: .random(count: 16)) }
    public var hex: String { raw.hex }
    public var description: String { raw.hex }
}

public enum ConversationKind: String, Sendable, Codable, CaseIterable {
    case direct, group, channel, notes
}

public struct Conversation: Hashable, Sendable, Codable, Identifiable {
    public let id: ConversationID
    public var kind: ConversationKind
    public var title: String
    public var members: [Address]
    public var isPinned = false
    public var isMuted = false
    public var isArchived = false
    public var unreadCount = 0
    public var isVerified = false
    public var lastMessage: Message?
    /// Seconds; 0 means messages never disappear.
    public var disappearingAfter: UInt32 = 0

    public init(id: ConversationID, kind: ConversationKind, title: String, members: [Address]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.members = members
    }

    public var lastActivity: Date { lastMessage?.sentAt ?? .distantPast }
}

public struct MessageID: Hashable, Sendable, Codable {
    public let raw: Data
    public init(raw: Data) { self.raw = raw }
    public static func random() -> MessageID { MessageID(raw: .random(count: 16)) }
}

public enum Sender: Hashable, Sendable, Codable {
    case me
    case contact(Address)
}

/// Send states from PLAN.md "Offline use and reliable delivery".
public enum DeliveryState: String, Sendable, Codable {
    case queued, sending, sent, delivered, read, failed
}

public struct AttachmentRef: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case image, video, file, voice }
    public var kind: Kind
    public var byteCount: Int
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Small inline preview (a few hundred bytes), shown until the bulk lane delivers the chunks.
    public var preview: Data?

    public init(kind: Kind, byteCount: Int, pixelWidth: Int? = nil, pixelHeight: Int? = nil, preview: Data? = nil) {
        self.kind = kind
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.preview = preview
    }
}

public enum MessageBody: Hashable, Sendable, Codable {
    case text(String)
    case attachment(AttachmentRef, caption: String?)

    public var previewText: String {
        switch self {
        case .text(let t):
            return t
        case .attachment(let a, let caption):
            if let caption, !caption.isEmpty {
                switch a.kind {
                case .voice: return "Voice · \(caption)"
                case .video: return "Video · \(caption)"
                case .image: return "Photo · \(caption)"
                case .file: return "File · \(caption)"
                }
            }
            switch a.kind {
            case .voice: return "Voice note"
            case .video: return "Video note"
            case .image: return "Photo"
            case .file: return "Attachment"
            }
        }
    }
}

public struct Message: Hashable, Sendable, Codable, Identifiable {
    public let id: MessageID
    public let conversationID: ConversationID
    public let sender: Sender
    public var body: MessageBody
    public let sentAt: Date
    public var state: DeliveryState

    public init(id: MessageID, conversationID: ConversationID, sender: Sender, body: MessageBody, sentAt: Date, state: DeliveryState) {
        self.id = id
        self.conversationID = conversationID
        self.sender = sender
        self.body = body
        self.sentAt = sentAt
        self.state = state
    }

    public var isMine: Bool { sender == .me }
}

public struct OutgoingMessage: Sendable {
    public var body: MessageBody
    public init(body: MessageBody) { self.body = body }
    public static func text(_ s: String) -> OutgoingMessage { OutgoingMessage(body: .text(s)) }
}

public enum ConversationChange: Sendable {
    case pin(Bool), mute(Bool), archive(Bool), markRead, markUnread
}

public enum ConnectionState: Hashable, Sendable {
    case offline
    case connecting
    case connected(network: String, nodes: Int)
    case failed(String)
}

public enum KhensuError: Error, Equatable, Sendable, LocalizedError {
    case noIdentity
    case identityExists
    case invalidAddress
    case invalidHandle
    case invalidInvite
    case unknownConversation
    case emptyMessage
    case invalidDevnetConfig(String)
    case invalidState
    case keychain(Int32)
    case core(String)

    public var errorDescription: String? {
        switch self {
        case .noIdentity: "No identity on this device yet."
        case .identityExists: "This device already has an identity."
        case .invalidAddress: "That isn't a valid khensu address."
        case .invalidHandle: "Handles are 3 to 32 letters, digits or underscores."
        case .invalidInvite: "That code isn't a khensu.nu contact code."
        case .unknownConversation: "That chat no longer exists."
        case .emptyMessage: "Nothing to send."
        case .invalidDevnetConfig(let why): "Devnet config not valid: \(why)"
        case .invalidState: "The saved state couldn't be read."
        case .keychain(let status): "Keychain error \(status)."
        case .core(let why): why
        }
    }
}

extension Data {
    public static func random(count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
