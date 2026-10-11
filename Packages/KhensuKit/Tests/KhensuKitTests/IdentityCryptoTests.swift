// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import Testing
@testable import KhensuKit

@Suite("Encodings")
struct EncodingTests {
    @Test("QUIC varints match RFC 9000 appendix A.1")
    func varints() {
        #expect(IdentityCrypto.varint(37).hex == "25")
        #expect(IdentityCrypto.varint(15293).hex == "7bbd")
        #expect(IdentityCrypto.varint(494_878_333).hex == "9d7f3e7d")
        #expect(IdentityCrypto.varint(151_288_809_941_952_652).hex == "c2197c5eff14e88c")
    }

    @Test("Bech32m accepts BIP-350 vectors and rejects bad checksums")
    func bech32mVectors() throws {
        for valid in ["A1LQFN3A", "a1lqfn3a", "abcdef1l7aum6echk45nj3s0wdvt2fg8x9yrzpqzd3ryx", "?1v759aa"] {
            #expect(Bech32m.decode(valid) != nil, "\(valid)")
        }
        for invalid in ["A1LQFN3B", "abcdef1l7aum6echk45nj3s0wdvt2fg8x9yrzpqzd3ryy", "1qyrz8wqe", "A1lqfn3a"] {
            #expect(Bech32m.decode(invalid) == nil, "\(invalid)")
        }
    }

    @Test("Addresses round-trip through khensu1...")
    func addressRoundTrip() throws {
        let address = try Address(bytes: .random(count: 32))
        let text = address.bech32m
        #expect(text.hasPrefix("khensu1"))
        #expect(try Address(bech32m: text) == address)
        #expect(throws: KhensuError.invalidAddress) { try Address(bech32m: "bc1" + text.dropFirst(7)) }
        #expect(throws: KhensuError.invalidAddress) { try Address(bytes: Data(count: 31)) }
    }

    @Test("Handles normalise per PROTOCOL.md 3.5")
    func handles() throws {
        #expect(try Handle("@Elliott").name == "elliott")
        #expect(try Handle("ana_88.khensu.nu").name == "ana_88")
        #expect(try Handle("ＡＮＡ").name == "ana") // fullwidth → NFKC
        #expect(try Handle("thoth").domain == "thoth.khensu.nu")
        for bad in ["ab", "has space", "dash-ed", String(repeating: "a", count: 33), "émile"] {
            #expect(throws: KhensuError.invalidHandle, "\(bad)") { try Handle(bad) }
        }
    }
}

@Suite("Identity crypto")
struct IdentityCryptoTests {
    @Test("Recovery phrase matches BIP-39 vectors and round-trips")
    func recoveryPhrase() throws {
        let zeros = IdentityCrypto.recoveryPhrase(entropy: Data(count: 32))
        #expect(zeros == Array(repeating: "abandon", count: 23) + ["art"])
        let sevenF = IdentityCrypto.recoveryPhrase(entropy: Data(repeating: 0x7F, count: 32))
        #expect(sevenF.joined(separator: " ") == "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title")
        let entropy = Data.random(count: 32)
        let words = IdentityCrypto.recoveryPhrase(entropy: entropy)
        #expect(words.count == 24)
        #expect(IdentityCrypto.entropy(fromPhrase: words) == entropy)
        #expect(IdentityCrypto.entropy(fromPhrase: Array(repeating: "abandon", count: 24)) == nil, "checksum must fail")
        #expect(IdentityCrypto.entropy(fromPhrase: Array(repeating: "notaword", count: 24)) == nil)
        #expect(IdentityCrypto.entropy(fromPhrase: Array(words.dropLast())) == nil)
    }

    @Test("Recovery key derivation is deterministic")
    func recoveryKey() throws {
        let phrase = IdentityCrypto.recoveryPhrase(entropy: Data(repeating: 1, count: 32))
        let s1 = IdentityCrypto.recoverySeed(phrase: phrase, iterations: 1024)
        let s2 = IdentityCrypto.recoverySeed(phrase: phrase, iterations: 1024)
        #expect(s1.count == 64 && s1 == s2)
        #expect(IdentityCrypto.recoverySeed(phrase: phrase, iterations: 1025) != s1)
        let k1 = try IdentityCrypto.recoveryKey(seed: s1)
        let k2 = try IdentityCrypto.recoveryKey(seed: s2)
        #expect(k1.publicKey.rawRepresentation == k2.publicKey.rawRepresentation)
        #expect(k1.publicKey.rawRepresentation.count == 2592)
        #expect(IdentityCrypto.expand(seed: s1, label: "backup key", count: 32) != IdentityCrypto.expand(seed: s1, label: "wallet seed", count: 32))
    }

    @Test("HKDF-Expand matches CryptoKit's HKDF-SHA-512")
    func expandMatchesCryptoKit() {
        let prk = Data.random(count: 64)
        let ours = IdentityCrypto.expand(seed: prk, label: "x", count: 100)
        let theirs = HKDF<SHA512>.expand(pseudoRandomKey: prk, info: IdentityCrypto.label("x"), outputByteCount: 100)
        #expect(ours == theirs.withUnsafeBytes { Data($0) })
    }

    @Test("The address depends on every identity key and the recovery commitment")
    func address() throws {
        let k1 = try MLDSA87.PrivateKey().publicKey.rawRepresentation
        let k2 = try MLDSA87.PrivateKey().publicKey.rawRepresentation
        let c = IdentityCrypto.nextKeyCommitment(recoveryPublicKey: k2)
        let a = IdentityCrypto.address(inception: IdentityCrypto.inceptionBytes(identityKeys: [k1], nextKeyCommitment: c))
        let same = IdentityCrypto.address(inception: IdentityCrypto.inceptionBytes(identityKeys: [k1], nextKeyCommitment: c))
        let other = IdentityCrypto.address(inception: IdentityCrypto.inceptionBytes(identityKeys: [k2], nextKeyCommitment: c))
        let otherCommit = IdentityCrypto.address(inception: IdentityCrypto.inceptionBytes(identityKeys: [k1], nextKeyCommitment: IdentityCrypto.nextKeyCommitment(recoveryPublicKey: k1)))
        #expect(a == same)
        #expect(a != other && a != otherCommit)
    }

    @Test("Safety numbers: six five-digit groups, order-independent pairs, four-word phrase")
    func safetyNumbers() throws {
        let me = (keys: [Data.random(count: 2592)], address: try Address(bytes: .random(count: 32)))
        let them = (keys: [Data.random(count: 2592), Data.random(count: 2592)], address: try Address(bytes: .random(count: 32)))
        let groups = IdentityCrypto.safetyNumber(identityKeys: them.keys, address: them.address)
        #expect(groups.count == 6 && groups.allSatisfy { $0.count == 5 && $0.allSatisfy(\.isNumber) })
        #expect(IdentityCrypto.safetyNumber(identityKeys: them.keys.reversed(), address: them.address) == groups)
        let ab = SafetyNumber.pair(mine: me, theirs: them)
        let ba = SafetyNumber.pair(mine: them, theirs: me)
        #expect(ab.groups == ba.groups)
        #expect(ab.qrPayload == ba.qrPayload)
        #expect(ab.checkPhrase.count == 4 && ab.checkPhrase.allSatisfy(Wordlist.english.contains))
        #expect(ab.checkPhrase == IdentityCrypto.checkPhrase(identityKeys: them.keys, address: them.address))
    }

    @Test("Contact invites round-trip through their URL")
    func invites() throws {
        let invite = ContactInvite(address: try Address(bytes: .random(count: 32)), displayName: "Ana Ferreira", handle: try Handle("ana"), keyFingerprint: .random(count: 32))
        let parsed = try ContactInvite(parsing: invite.url.absoluteString)
        #expect(parsed == invite)
        #expect(invite.url.absoluteString.hasPrefix("https://khensu.nu/c/khensu1"))
        #expect(throws: KhensuError.invalidInvite) { try ContactInvite(parsing: "https://example.com/c/x") }
        #expect(throws: KhensuError.invalidInvite) { try ContactInvite(parsing: "https://khensu.nu/c/\(invite.address.bech32m)?n=x") }
    }
}
