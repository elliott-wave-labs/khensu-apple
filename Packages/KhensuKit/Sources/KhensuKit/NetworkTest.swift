// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// What the core knows about the network it is on, for the Network test screen.
/// Mirrors khensu-core's `NetworkStatus` (`ffi/SWIFT-API.md`).
public struct NetworkStatus: Hashable, Sendable {
    public var network: String
    /// Epoch from the clock.
    public var epoch: UInt64
    /// Epoch of the header the client is using.
    public var headerEpoch: UInt64
    /// The next header, already accepted and waiting for the boundary.
    public var nextHeaderEpoch: UInt64?
    public var nodes: Int
    public var committee: Int
    public var mailboxReplicas: Int
    public var gateway: String
    public var ticks: UInt64
    public var pending: Int
    public var loopsSent: UInt64
    public var loopsReturned: UInt64
    public var lastLoopRTTMs: UInt64?
    public var headersAccepted: UInt64
    public var storeReceiptsOK: UInt64
    public var storeReceiptsBad: UInt64

    public init(network: String, epoch: UInt64, headerEpoch: UInt64, nextHeaderEpoch: UInt64?, nodes: Int, committee: Int,
                mailboxReplicas: Int, gateway: String, ticks: UInt64, pending: Int, loopsSent: UInt64, loopsReturned: UInt64,
                lastLoopRTTMs: UInt64?, headersAccepted: UInt64, storeReceiptsOK: UInt64, storeReceiptsBad: UInt64) {
        self.network = network
        self.epoch = epoch
        self.headerEpoch = headerEpoch
        self.nextHeaderEpoch = nextHeaderEpoch
        self.nodes = nodes
        self.committee = committee
        self.mailboxReplicas = mailboxReplicas
        self.gateway = gateway
        self.ticks = ticks
        self.pending = pending
        self.loopsSent = loopsSent
        self.loopsReturned = loopsReturned
        self.lastLoopRTTMs = lastLoopRTTMs
        self.headersAccepted = headersAccepted
        self.storeReceiptsOK = storeReceiptsOK
        self.storeReceiptsBad = storeReceiptsBad
    }

    /// Loops that came back, as a fraction of those sent; nil before the first.
    public var loopReturnRate: Double? {
        loopsSent == 0 ? nil : Double(loopsReturned) / Double(loopsSent)
    }
}

/// Network test settings: how much of the client's cover becomes loop probes,
/// and whether mailboxes are asked to sign for what they store.
public struct NetworkTestOptions: Hashable, Sendable {
    /// Loop probes per 100 ticks (0 to 100). 0 sends none.
    public var loopsPer100Ticks: UInt32
    public var storeReceipts: Bool

    public init(loopsPer100Ticks: UInt32 = 0, storeReceipts: Bool = false) {
        self.loopsPer100Ticks = min(loopsPer100Ticks, 100)
        self.storeReceipts = storeReceipts
    }

    public static let off = NetworkTestOptions()
    public static let full = NetworkTestOptions(loopsPer100Ticks: 100, storeReceipts: true)
}

/// Events the core reports about the network itself (not about messages).
public enum NetworkEvent: Hashable, Sendable {
    /// A loop probe came back through the gateway and the mixes.
    case loopReturned(rttMs: UInt64, hops: Int)
    /// The entry node sent the next epoch header and it checked out.
    case headerAccepted(epoch: UInt64, nodes: Int, committee: Int)
    /// A mailbox replica signed for an item it stored (`valid` false: the signature failed).
    case storeReceipt(replica: String, epoch: UInt64, valid: Bool)
}

public enum LogLevel: Int, Hashable, Sendable, Comparable, CaseIterable {
    case trace, debug, info, warn, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .trace: "trace"
        case .debug: "debug"
        case .info: "info"
        case .warn: "warn"
        case .error: "error"
        }
    }
}

/// One line from the core's log: the event name and its structured fields.
public struct LogLine: Hashable, Sendable, Identifiable {
    public let id: UInt64
    public let time: Date
    public let level: LogLevel
    /// The module that logged it (`khensu_ffi::core`, `MockCore`).
    public let target: String
    /// The event name (`loop.returned`, `header.accepted`).
    public let message: String
    /// `key=value` pairs.
    public let fields: String

    public init(id: UInt64, time: Date, level: LogLevel, target: String, message: String, fields: String) {
        self.id = id
        self.time = time
        self.level = level
        self.target = target
        self.message = message
        self.fields = fields
    }

    /// `12:34:56.789 info  loop.returned rtt_ms=2001 hops=5`
    public var text: String {
        let t = Self.clock.string(from: time)
        return "\(t) \(level.label.padding(toLength: 5, withPad: " ", startingAt: 0)) \(message)\(fields.isEmpty ? "" : " " + fields)"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// The core's log, kept in memory for the Network test screen: the last
/// `capacity` lines and a stream of new ones. `RustCore` feeds it from
/// khensu-core's `LogSink`; `MockCore` writes its own lines. Nothing here is
/// written to disk and nothing leaves the device unless the user shares it.
public final class CoreLog: @unchecked Sendable {
    public static let shared = CoreLog()

    public let capacity: Int
    private let lock = NSLock()
    private var lines: [LogLine] = []
    private var next: UInt64 = 1
    private var subscribers: [UUID: AsyncStream<LogLine>.Continuation] = [:]

    public init(capacity: Int = 2_000) {
        self.capacity = capacity
    }

    public func append(level: LogLevel, target: String, message: String, fields: String = "", time: Date = .now) {
        let line: LogLine
        let subs: [AsyncStream<LogLine>.Continuation]
        lock.lock()
        line = LogLine(id: next, time: time, level: level, target: target, message: message, fields: fields)
        next += 1
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        subs = Array(subscribers.values)
        lock.unlock()
        for s in subs { s.yield(line) }
    }

    /// The lines kept so far, oldest first.
    public func snapshot() -> [LogLine] {
        lock.withLock { lines }
    }

    public func clear() {
        lock.withLock { lines.removeAll() }
    }

    /// New lines as they arrive.
    public func stream() -> AsyncStream<LogLine> {
        let (stream, continuation) = AsyncStream.makeStream(of: LogLine.self, bufferingPolicy: .bufferingNewest(512))
        let id = UUID()
        lock.withLock { subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { self?.subscribers[id] = nil }
        }
        return stream
    }

    /// Everything as text, for sharing.
    public func export() -> String {
        snapshot().map(\.text).joined(separator: "\n")
    }
}
