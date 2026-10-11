// SPDX-License-Identifier: AGPL-3.0-only

import CommonCrypto
import CryptoKit
import Foundation

/// Client-side pieces of PROTOCOL.md sections 1, 3.1, 3.2 and 3.6 that the app
/// needs before (and independently of) the Rust core: labels, the address,
/// the recovery phrase, safety numbers and the four-word check phrase.
///
/// khensu-core's vectors are authoritative; `IdentityCryptoTests` pins the
/// encodings used here so a mismatch shows up as a test failure.
public enum IdentityCrypto {
    /// `Label(x) = "khensu v1 " || x`
    public static func label(_ x: String) -> Data { Data("khensu v1 \(x)".utf8) }

    /// QUIC variable-length integer (RFC 9000 §16), used for `<V>` vectors.
    public static func varint(_ value: UInt64) -> Data {
        switch value {
        case 0..<(1 << 6): return Data([UInt8(value)])
        case 0..<(1 << 14): return withUnsafeBytes(of: (UInt16(value) | 0x4000).bigEndian) { Data($0) }
        case 0..<(1 << 30): return withUnsafeBytes(of: (UInt32(value) | 0x8000_0000).bigEndian) { Data($0) }
        default:
            precondition(value < (1 << 62), "varint out of range")
            return withUnsafeBytes(of: (value | 0xC000_0000_0000_0000).bigEndian) { Data($0) }
        }
    }

    public static func vector(_ data: Data) -> Data { varint(UInt64(data.count)) + data }

    public static func h(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for p in parts { hasher.update(data: p) }
        return Data(hasher.finalize())
    }

    // MARK: Address (3.1, 3.3)

    /// `H(Label("next key") || recovery_pk)`
    public static func nextKeyCommitment(recoveryPublicKey: Data) -> Data {
        h(label("next key"), recoveryPublicKey)
    }

    /// Serialized `Inception { identity_keys<V>; next_key_commitment[64] }`.
    public static func inceptionBytes(identityKeys: [Data], nextKeyCommitment: Data) -> Data {
        precondition(nextKeyCommitment.count == 64)
        return vector(identityKeys.reduce(Data(), +)) + nextKeyCommitment
    }

    /// `SHA3-256(Label("address") || inception_event_bytes)`
    public static func address(inception: Data) -> Address {
        var hasher = SHA3_256()
        hasher.update(data: label("address"))
        hasher.update(data: inception)
        // 32 bytes by construction.
        return try! Address(bytes: Data(hasher.finalize()))
    }

    // MARK: Safety number (3.6)

    public static func safetyHash(identityKeys: [Data], address: Address) -> Data {
        let sorted = identityKeys.sorted { $0.lexicographicallyPrecedes($1) }
        return h(label("safety number"), sorted.reduce(Data(), +), address.bytes)
    }

    /// Six groups of five digits: each group is a big-endian 40-bit chunk of the hash, mod 100,000.
    public static func safetyNumber(identityKeys: [Data], address: Address) -> [String] {
        let digest = Array(safetyHash(identityKeys: identityKeys, address: address))
        return (0..<6).map { i in
            let chunk = digest[(i * 5)..<(i * 5 + 5)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return String(format: "%05llu", chunk % 100_000)
        }
    }

    /// First 44 bits of the safety hash, as four 11-bit indices into the 2,048-word list.
    public static func checkPhrase(identityKeys: [Data], address: Address) -> [String] {
        let digest = Array(safetyHash(identityKeys: identityKeys, address: address))
        let bits = digest[0..<6].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } >> 4
        return (0..<4).map { i in Wordlist.english[Int((bits >> UInt64(33 - 11 * i)) & 0x7FF)] }
    }

    // MARK: Recovery phrase (3.2)

    /// 24 words from 256 bits of entropy plus an 8-bit SHA-256 checksum (BIP-39 layout).
    public static func recoveryPhrase(entropy: Data) -> [String] {
        precondition(entropy.count == 32)
        let checksum = Data(SHA256.hash(data: entropy)).first!
        let bytes = Array(entropy) + [checksum]
        var words: [String] = []
        var acc = 0, bits = 0
        for b in bytes {
            acc = (acc << 8) | Int(b)
            bits += 8
            while bits >= 11 {
                bits -= 11
                words.append(Wordlist.english[(acc >> bits) & 0x7FF])
            }
            acc &= (1 << bits) - 1
        }
        return words
    }

    /// Inverse of `recoveryPhrase(entropy:)`; nil if a word is unknown or the checksum fails.
    public static func entropy(fromPhrase words: [String]) -> Data? {
        guard words.count == 24 else { return nil }
        var acc = 0, bits = 0
        var out: [UInt8] = []
        for w in words {
            guard let i = Wordlist.index[w.lowercased()] else { return nil }
            acc = (acc << 11) | i
            bits += 11
            while bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> bits) & 0xFF))
            }
            acc &= (1 << bits) - 1
        }
        guard out.count == 33 else { return nil }
        let entropy = Data(out[0..<32])
        return Data(SHA256.hash(data: entropy)).first == out[32] ? entropy : nil
    }

    /// `PBKDF2-HMAC-SHA-512(phrase, "khensu v1 recovery" || address_hint, iterations)`
    public static func recoverySeed(phrase: [String], addressHint: Data = Data(), iterations: UInt32 = 1 << 20) -> Data {
        let password = phrase.joined(separator: " ")
        let salt = [UInt8](label("recovery") + addressHint)
        var out = [UInt8](repeating: 0, count: 64)
        let status = password.withCString { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), pw, strlen(pw),
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), iterations,
                &out, out.count
            )
        }
        precondition(status == kCCSuccess)
        return Data(out)
    }

    /// `KDF.Expand(seed, Label(label), length)` with HKDF-SHA-512.
    public static func expand(seed: Data, label name: String, count: Int) -> Data {
        // HKDF-Expand only: the PBKDF2 output is already a uniform PRK.
        var okm = Data()
        var t = Data()
        var i: UInt8 = 1
        let key = SymmetricKey(data: seed)
        while okm.count < count {
            var mac = HMAC<SHA512>(key: key)
            mac.update(data: t)
            mac.update(data: label(name))
            mac.update(data: [i])
            t = Data(mac.finalize())
            okm += t
            i += 1
        }
        return okm.prefix(count)
    }

    public static func recoveryKey(seed: Data) throws -> MLDSA87.PrivateKey {
        try MLDSA87.PrivateKey(seedRepresentation: expand(seed: seed, label: "recovery key", count: 32), publicKey: nil)
    }
}
