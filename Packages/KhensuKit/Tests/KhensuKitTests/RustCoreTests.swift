// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(KhensuCoreBindings)
import CryptoKit
import Foundation
import Testing
@testable import KhensuKit

/// Runs khensu-core itself (linked by scripts/link-core.sh). Network paths need
/// a running devnet and are exercised from the app's Devnet screen.
@Suite("RustCore")
struct RustCoreTests {
    private func newCore(_ name: String) async throws -> (RustCore, Identity) {
        let core = RustCore()
        let new = try await core.createIdentity(displayName: name, handle: try Handle(name.lowercased()), identityKey: Data())
        return (core, new.identity)
    }

    @Test("khensu-core creates an ML-DSA-87 identity with a khensu1 address")
    func identity() async throws {
        let (core, identity) = try await newCore("Ana")
        #expect(identity.identityKeys.first?.count == 2592)
        #expect(identity.address.bech32m.hasPrefix("khensu1"))
        #expect(identity.handle?.status == .pending)
        #expect(await core.currentIdentity()?.address == identity.address)
        await #expect(throws: KhensuError.identityExists) {
            try await core.createIdentity(displayName: "x", handle: nil, identityKey: Data())
        }
    }

    @Test("Contact cards travel in the invite link and open a direct chat")
    func contactCards() async throws {
        let (ana, anaID) = try await newCore("Ana")
        let (ra, _) = try await newCore("Ramses")
        let invite = try await ana.myInvite()
        let card = try #require(invite.card)
        #expect(!card.isEmpty)
        let parsed = try ContactInvite(parsing: invite.url.absoluteString)
        #expect(parsed.card == card && parsed.address == anaID.address)

        let chat = try await ra.addContact(parsed)
        #expect(chat.kind == .direct && chat.title == "Ana")
        #expect(await ra.conversations().map(\.id) == [chat.id])
        #expect(try await ra.addContact(parsed).id == chat.id, "adding twice reuses the chat")

        let sent = try await ra.send(.text("hello through the mixnet"), to: chat.id)
        #expect(sent.state == .queued)
        #expect(try await ra.messages(in: chat.id).count == 1)
        await #expect(throws: KhensuError.self) {
            try await ra.send(OutgoingMessage(body: .attachment(AttachmentRef(kind: .image, byteCount: 1), caption: nil)), to: chat.id)
        }
        #expect(try await ra.safetyNumber(with: anaID.address).groups.count == 6)
        print("contact invite link: \(invite.url.absoluteString.utf8.count) bytes, fits QR: \(invite.fitsQRCode)")
    }

    @Test("State export and import restore the client, chats and history")
    func exportImport() async throws {
        let (ana, _) = try await newCore("Ana")
        let (ra, raID) = try await newCore("Ramses")
        let chat = try await ra.addContact(try await ana.myInvite())
        _ = try await ra.send(.text("keep me"), to: chat.id)
        try await ra.update(chat.id, .pin(true))

        let blob = try await ra.exportState()
        let restored = RustCore()
        try await restored.importState(blob)
        #expect(await restored.currentIdentity()?.address == raID.address)
        let convo = try #require(await restored.conversations().first)
        #expect(convo.id == chat.id && convo.isPinned)
        #expect(try await restored.messages(in: chat.id).map(\.body) == [.text("keep me")])
        await #expect(throws: KhensuError.invalidState) { try await restored.importState(Data("x".utf8)) }
    }
}
#endif
