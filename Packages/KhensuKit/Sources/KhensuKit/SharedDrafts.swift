// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Text and links handed over by the Share Extension. The extension can't open
/// the encrypted store or pick a chat (the store key is only released by the
/// app unlock), so it leaves items here and the app asks where to send them.
/// The file uses Complete protection: readable only while the device is unlocked.
public struct SharedDrafts: Sendable {
    public static let maxItems = 20
    public static let maxLength = 8_000

    public let url: URL

    public init(url: URL) { self.url = url }

    public static func shared() -> SharedDrafts? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: IncomingQueue.appGroup)
            .map { SharedDrafts(url: $0.appendingPathComponent("shared-drafts.json")) }
    }

    public func add(_ text: String) throws {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        guard !trimmed.isEmpty else { return }
        var items = try peek()
        items.append(trimmed)
        try write(Array(items.suffix(Self.maxItems)))
    }

    public func peek() throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
    }

    /// Returns every item and clears the file.
    public func take() throws -> [String] {
        let items = try peek()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        return items
    }

    private func write(_ items: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: url, options: [.atomic, .completeFileProtection])
    }
}
