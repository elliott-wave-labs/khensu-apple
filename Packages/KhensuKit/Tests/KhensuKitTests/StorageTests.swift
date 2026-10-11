// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import Testing
@testable import KhensuKit

@Suite("Storage")
struct StorageTests {
    @Test("The incoming queue keeps packets in order until drained")
    func incomingQueue() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = IncomingQueue(url: dir.appendingPathComponent("incoming.queue"))
        #expect(try queue.drain().isEmpty)
        let packets = (1...5).map { Data.random(count: $0 * 100) }
        try queue.append(Array(packets[0..<2]))
        try queue.append(Array(packets[2...]))
        #expect(try queue.count() == 5)
        #expect(try queue.drain() == packets)
        #expect(try queue.drain().isEmpty)
        #expect(throws: KhensuError.invalidState) { try queue.append([Data()]) }
        #expect(throws: KhensuError.invalidState) { try queue.append([Data(count: IncomingQueue.maxPacketSize + 1)]) }
    }

    @Test("A truncated queue file is rejected")
    func truncatedQueue() {
        #expect(throws: KhensuError.invalidState) { try IncomingQueue.parse(Data([0, 0, 0, 9, 1, 2])) }
        #expect(throws: KhensuError.invalidState) { try IncomingQueue.parse(Data([0, 0])) }
    }

    @Test("Devnet configs need a JSON object with endpoints")
    func devnetConfig() throws {
        let json = #"{"network":"khensu-devnet","mixnet":[{"addr":"127.0.0.1:7001"},{"addr":"127.0.0.1:7002"}],"push":"http://127.0.0.1:8080","keys":{"node":"abcd"}}"#
        let config = try DevnetConfig(string: json)
        #expect(config.name == "khensu-devnet")
        #expect(config.endpoints == ["127.0.0.1:7001", "127.0.0.1:7002", "http://127.0.0.1:8080"])
        #expect(throws: KhensuError.invalidDevnetConfig("not JSON")) { try DevnetConfig(string: "nope") }
        #expect(throws: KhensuError.invalidDevnetConfig("expected a JSON object")) { try DevnetConfig(string: "[1]") }
        #expect(throws: KhensuError.invalidDevnetConfig("no endpoints found")) { try DevnetConfig(string: #"{"a":1}"#) }
    }

    @Test("Vault: identity key signs, store key seals only while unlocked")
    func vault() async throws {
        let vault = DeviceVault(store: MemorySecretStore(), allowSecureEnclave: false)
        #expect(vault.hardware == .software)
        let pk = try vault.createIdentityKey()
        #expect(try vault.identityPublicKey() == pk)
        #expect(throws: KhensuError.identityExists) { try vault.createIdentityKey() }

        let sig = try await vault.signWithIdentity(label: "log entry", content: Data("hello".utf8), reason: "test")
        let signed = IdentityCrypto.vector(IdentityCrypto.label("log entry")) + IdentityCrypto.vector(Data("hello".utf8))
        #expect(try MLDSA87.PublicKey(rawRepresentation: pk).isValidSignature(sig, for: signed))

        try vault.createStoreKey(policy: .none)
        let box = try vault.seal(Data("history".utf8))
        vault.lockNow()
        #expect(!vault.isUnlocked)
        #expect(throws: KhensuError.invalidState) { try vault.open(box) }
        try await vault.unlock(reason: "test")
        #expect(try vault.open(box) == Data("history".utf8))

        try vault.changePolicy(.none)
        vault.lockNow()
        try await vault.unlock(reason: "test")
        #expect(try vault.open(box) == Data("history".utf8), "re-wrapping keeps the same store key")

        try vault.changePolicy(.biometricsOrPasscode)
        #expect(vault.currentPolicy() == .biometricsOrPasscode)

        try vault.wipe()
        #expect(!vault.hasStoreKey)
        #expect(try vault.identityPublicKey() == nil)
        await #expect(throws: KhensuError.noIdentity) { try await vault.unlock(reason: "test") }
    }
}
