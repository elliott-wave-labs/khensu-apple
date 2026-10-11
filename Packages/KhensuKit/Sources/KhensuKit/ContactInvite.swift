// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

/// What a contact QR code or link carries:
/// `https://khensu.nu/c/<khensu1...>?n=<name>&h=<handle>&f=<fingerprint>`.
///
/// ML-DSA-87 keys (2,592 bytes each) don't fit a scannable QR code, so the code
/// carries a 32-byte fingerprint of the identity keys. The full keys arrive with
/// the first message (or from the key transparency log once it exists) and must
/// match the fingerprint.
///
/// With khensu-core, the invite also carries a one-time contact card (a signed
/// KeyPackage, base64) in the URL fragment, which browsers never send to a
/// server. Cards are several kilobytes, so those invites are shared as links.
public struct ContactInvite: Hashable, Sendable, Codable {
    public let address: Address
    public let displayName: String
    public let handle: Handle?
    public let keyFingerprint: Data
    public let card: String?

    public init(address: Address, displayName: String, handle: Handle?, keyFingerprint: Data, card: String? = nil) {
        self.address = address
        self.displayName = displayName
        self.handle = handle
        self.keyFingerprint = keyFingerprint
        self.card = card
    }

    /// Largest payload a QR code holds reliably at error correction level M.
    public static let maxQRBytes = 2_300

    public var fitsQRCode: Bool { url.absoluteString.utf8.count <= Self.maxQRBytes }

    public init(identity: Identity) {
        self.init(
            address: identity.address,
            displayName: identity.displayName,
            handle: identity.handle,
            keyFingerprint: Self.fingerprint(identity.identityKeys)
        )
    }

    /// First 32 bytes of `H(Label("key fingerprint") || sorted keys)`.
    public static func fingerprint(_ keys: [Data]) -> Data {
        let sorted = keys.sorted { $0.lexicographicallyPrecedes($1) }
        return Data(SHA512.hash(data: IdentityCrypto.label("key fingerprint") + sorted.reduce(Data(), +))).prefix(32)
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "khensu.nu"
        c.path = "/c/\(address.bech32m)"
        var items = [URLQueryItem(name: "n", value: displayName)]
        if let handle { items.append(URLQueryItem(name: "h", value: handle.name)) }
        items.append(URLQueryItem(name: "f", value: keyFingerprint.hex))
        c.queryItems = items
        c.fragment = card
        return c.url!
    }

    public init(parsing string: String) throws(KhensuError) {
        guard let c = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "https", c.host == "khensu.nu",
              c.path.hasPrefix("/c/")
        else { throw .invalidInvite }
        let address = try Address(bech32m: String(c.path.dropFirst(3)))
        let q = Dictionary((c.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        guard let f = q["f"], let fingerprint = Data(hex: f), fingerprint.count == 32 else { throw .invalidInvite }
        let name = (q["n"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            address: address,
            displayName: name.isEmpty ? address.short : String(name.prefix(64)),
            handle: try q["h"].map { h throws(KhensuError) in try Handle(h) },
            keyFingerprint: fingerprint,
            card: c.fragment.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

extension Data {
    public init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: hex.count / 2)
        var it = hex.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            guard let byte = UInt8(String([hi, lo]), radix: 16) else { return nil }
            out.append(byte)
        }
        self = out
    }
}
