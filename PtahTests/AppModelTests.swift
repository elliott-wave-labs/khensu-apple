// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import KhensuKit
import Testing
@testable import Ptah

@MainActor
@Suite("App lock and persistence")
struct AppModelTests {
    private func makeModel(policyLock: Bool) -> (AppModel, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sealed")
        let vault = DeviceVault(store: MemorySecretStore(), allowSecureEnclave: false, softwareKeysAuthenticate: false)
        let model = AppModel(core: MockCore(timing: .instant), vault: vault, stateURL: url, launch: LaunchOptions())
        return (model, url)
    }

    @Test("Onboarding creates an identity and seals state to disk")
    func onboarding() async throws {
        let (model, url) = makeModel(policyLock: false)
        defer { try? FileManager.default.removeItem(at: url) }
        await model.start()
        #expect(model.phase == .onboarding)
        let phrase = try await model.createIdentity(displayName: "Ana", handle: "ana", appLock: false)
        #expect(phrase.count == 24)
        await model.finishOnboarding()
        #expect(model.phase == .ready)
        #expect(model.identity?.handle?.status == .pending)
        let sealed = try Data(contentsOf: url)
        #expect(!sealed.isEmpty)
        #expect(sealed.range(of: Data("Ana".utf8)) == nil, "state on disk must be encrypted")
    }

    @Test("Locking drops plaintext; unlocking restores it from the sealed file")
    func lockUnlock() async throws {
        let (model, url) = makeModel(policyLock: true)
        defer { try? FileManager.default.removeItem(at: url) }
        await model.start()
        _ = try await model.createIdentity(displayName: "Ana", handle: "", appLock: true)
        await model.finishOnboarding()
        let ana = ContactInvite(address: try Address(bytes: .random(count: 32)), displayName: "Ra", handle: nil, keyFingerprint: .random(count: 32))
        let chat = try await model.addContact(ana)
        await model.send(.text("before lock"), to: chat.id)

        await model.lock()
        #expect(model.phase == .locked)
        #expect(model.conversations.isEmpty && model.identity == nil)
        #expect(await model.core.currentIdentity() == nil, "core forgets plaintext while locked")

        await model.unlock()
        #expect(model.phase == .ready)
        #expect(model.identity?.displayName == "Ana")
        #expect(try await model.core.messages(in: chat.id).map(\.body) == [.text("before lock")])
    }
}
