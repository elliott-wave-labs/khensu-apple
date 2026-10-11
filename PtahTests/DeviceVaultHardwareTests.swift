// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import KhensuKit
import Testing

/// Runs inside the app on a real device, where the Secure Enclave and the
/// app's keychain group exist. Uses the no-prompt policy so it can run
/// unattended; the Face ID policies are exercised by hand.
@Suite("Device vault on hardware")
struct DeviceVaultHardwareTests {
    @Test("Secure Enclave ML-DSA-87 identity key and ML-KEM-1024 store-key wrap")
    func secureEnclaveVault() async throws {
        let store = KeychainStore(service: "nu.khensu.ptah.tests.\(UUID().uuidString)")
        let vault = DeviceVault(store: store)
        defer { try? vault.wipe() }
        #if targetEnvironment(simulator)
        #expect(vault.hardware == .software)
        #else
        #expect(vault.hardware == .secureEnclave)
        #endif

        let pk = try vault.createIdentityKey()
        #expect(pk.count == 2592)
        #expect(try vault.identityPublicKey() == pk)

        try vault.createStoreKey(policy: .none)
        let box = try vault.seal(Data("history".utf8))
        vault.lockNow()
        #expect(throws: KhensuError.invalidState) { try vault.open(box) }
        try await vault.unlock(reason: "test")
        #expect(try vault.open(box) == Data("history".utf8))

        try vault.wipe()
        #expect(!vault.hasStoreKey)
        #expect(try vault.identityPublicKey() == nil)
    }

    @Test("The incoming queue lives in the App Group")
    func appGroupQueue() throws {
        let queue = try #require(IncomingQueue.shared(), "App Group container missing: check provisioning")
        _ = try queue.drain()
        try queue.append([Data("sealed".utf8)])
        #expect(try queue.drain() == [Data("sealed".utf8)])
    }
}
