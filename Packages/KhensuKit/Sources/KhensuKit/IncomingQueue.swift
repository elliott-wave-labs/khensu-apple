// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The sealed-packet queue shared by the Notification Service Extension and the
/// app (PLAN.md, "On-device biometrics": receiving while locked).
///
/// The file uses `NSFileProtectionCompleteUnlessOpen`, so the extension can
/// append while the phone is locked but nothing can read it until unlock.
/// Packets stay sealed: the extension never holds a key that opens them.
///
/// Format: a sequence of `[UInt32 big-endian length][packet bytes]` records.
public struct IncomingQueue: Sendable {
    public static let appGroup = "group.nu.khensu.ptah"
    public static let maxPacketSize = 64 * 1024

    public let url: URL

    public init(url: URL) { self.url = url }

    /// The queue in the shared App Group container, or nil if the group isn't provisioned.
    public static func shared() -> IncomingQueue? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { IncomingQueue(url: $0.appendingPathComponent("incoming.queue")) }
    }

    public func append(_ packets: [Data]) throws {
        guard !packets.isEmpty else { return }
        var records = Data()
        for p in packets {
            guard !p.isEmpty, p.count <= Self.maxPacketSize else { throw KhensuError.invalidState }
            withUnsafeBytes(of: UInt32(p.count).bigEndian) { records.append(contentsOf: $0) }
            records.append(p)
        }
        try coordinate(writing: true) { url in
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
                else { throw KhensuError.invalidState }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: records)
        }
    }

    /// Reads and removes every queued packet. Only works while the device is unlocked.
    public func drain() throws -> [Data] {
        var packets: [Data] = []
        try coordinate(writing: true) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            packets = try Self.parse(data)
            try FileManager.default.removeItem(at: url)
        }
        return packets
    }

    public func count() throws -> Int {
        var n = 0
        try coordinate(writing: false) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            n = try Self.parse(Data(contentsOf: url)).count
        }
        return n
    }

    static func parse(_ data: Data) throws -> [Data] {
        var out: [Data] = []
        var i = data.startIndex
        while i < data.endIndex {
            guard data.endIndex - i >= 4 else { throw KhensuError.invalidState }
            let len = data[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            i += 4
            guard len > 0, len <= maxPacketSize, data.endIndex - i >= len else { throw KhensuError.invalidState }
            out.append(Data(data[i..<i + len]))
            i += len
        }
        return out
    }

    private func coordinate(writing: Bool, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: (any Error)?
        let coordinator = NSFileCoordinator()
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { u in
                do { try body(u) } catch { bodyError = error }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { u in
                do { try body(u) } catch { bodyError = error }
            }
        }
        if let e = coordinationError ?? bodyError { throw e }
    }
}
