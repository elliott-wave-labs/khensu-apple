// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import Testing
@testable import KhensuKit

@Suite("MockCore")
struct MockCoreTests {
    private func newCore() async throws -> (MockCore, Identity, [String]) {
        let core = MockCore(timing: .instant)
        let key = try MLDSA87.PrivateKey().publicKey.rawRepresentation
        let new = try await core.createIdentity(displayName: "Elliott", handle: try Handle("elliott"), identityKey: key)
        return (core, new.identity, new.recoveryPhrase)
    }

    private func invite(_ name: String) throws -> ContactInvite {
        ContactInvite(address: try Address(bytes: .random(count: 32)), displayName: name, handle: nil, keyFingerprint: .random(count: 32))
    }

    @Test("Creating an identity derives the address and keeps the handle pending")
    func createIdentity() async throws {
        let (core, identity, phrase) = try await newCore()
        #expect(phrase.count == 24)
        #expect(identity.handle?.status == .pending)
        #expect(identity.handle?.domain == "elliott.khensu.nu")
        #expect(identity.address.bech32m.hasPrefix("khensu1"))
        #expect(await core.currentIdentity() == identity)
        await #expect(throws: KhensuError.identityExists) {
            try await core.createIdentity(displayName: "x", handle: nil, identityKey: Data(count: 2592))
        }
        let convos = await core.conversations()
        #expect(convos.map(\.kind) == [.notes])
    }

    @Test("Nothing works before an identity exists")
    func requiresIdentity() async throws {
        let core = MockCore(timing: .instant)
        await #expect(throws: KhensuError.noIdentity) { try await core.myInvite() }
        await #expect(throws: KhensuError.noIdentity) { try await core.addContact(try invite("Ana")) }
    }

    @Test("Adding a contact by invite opens one direct chat, idempotently")
    func addContact() async throws {
        let (core, me, _) = try await newCore()
        let ana = try invite("Ana")
        let c1 = try await core.addContact(ana)
        let c2 = try await core.addContact(ana)
        #expect(c1.id == c2.id && c1.kind == .direct && c1.title == "Ana")
        #expect(await core.contact(ana.address)?.displayName == "Ana")
        await #expect(throws: KhensuError.invalidInvite) { try await core.addContact(ContactInvite(identity: me)) }

        let number = try await core.safetyNumber(with: ana.address)
        #expect(number.groups.count == 6)
        try await core.setVerified(true, contact: ana.address)
        #expect(await core.conversations().first { $0.id == c1.id }?.isVerified == true)
    }

    @Test("Sent messages advance to delivered and emit events")
    func send() async throws {
        let (core, _, _) = try await newCore()
        let ana = try invite("Ana")
        let chat = try await core.addContact(ana)
        let events = await core.events()
        let sent = try await core.send(.text("hello"), to: chat.id)
        #expect(sent.state == .queued && sent.isMine)

        var states: [DeliveryState] = []
        for await event in events {
            if case .messageStateChanged(let id, _, let s) = event, id == sent.id { states.append(s) }
            if states.last == .delivered { break }
        }
        #expect(states == [.sending, .sent, .delivered])
        #expect(try await core.messages(in: chat.id).last?.state == .delivered)
        await #expect(throws: KhensuError.emptyMessage) { try await core.send(.text("  "), to: chat.id) }
        await #expect(throws: KhensuError.unknownConversation) { try await core.send(.text("x"), to: .random()) }
    }

    @Test("Received packets land in the right chat as unread, and are searchable")
    func receiveAndSearch() async throws {
        let (core, _, _) = try await newCore()
        let ana = try invite("Ana")
        let chat = try await core.addContact(ana)
        let packet = try JSONEncoder().encode(MockCore.MockPacket(from: ana.address, text: "Lisbon moved to May"))
        let stranger = try JSONEncoder().encode(MockCore.MockPacket(from: try Address(bytes: .random(count: 32)), text: "spam"))
        let got = try await core.receive(sealed: [packet, stranger, Data("garbage".utf8)])
        #expect(got.count == 1 && got[0].conversationID == chat.id)
        #expect(await core.conversations().first { $0.id == chat.id }?.unreadCount == 1)
        #expect(await core.search("lisbon").count == 1)
        #expect(await core.search("paris").isEmpty)
        #expect(await core.search(" ").isEmpty)
    }

    @Test("Pin, mute, archive and read flags; pinned chats sort first")
    func conversationChanges() async throws {
        let (core, _, _) = try await newCore()
        let a = try await core.addContact(try invite("A"))
        let b = try await core.addContact(try invite("B"))
        _ = try await core.send(.text("newest"), to: b.id)
        try await core.update(a.id, .pin(true))
        try await core.update(a.id, .mute(true))
        try await core.update(b.id, .archive(true))
        try await core.update(b.id, .markUnread)
        let list = await core.conversations()
        #expect(list.first?.id == a.id)
        #expect(list.first { $0.id == a.id }?.isMuted == true)
        #expect(list.first { $0.id == b.id }?.isArchived == true)
        #expect(list.first { $0.id == b.id }?.unreadCount == 1)
        try await core.update(b.id, .markRead)
        #expect(await core.conversations().first { $0.id == b.id }?.unreadCount == 0)
        await #expect(throws: KhensuError.unknownConversation) { try await core.update(.random(), .markRead) }
    }

    @Test("State export and import round-trip; wipe forgets everything")
    func exportImport() async throws {
        let (core, identity, _) = try await newCore()
        let chat = try await core.addContact(try invite("Ana"))
        _ = try await core.send(.text("keep me"), to: chat.id)
        let blob = try await core.exportState()

        let restored = MockCore(timing: .instant)
        try await restored.importState(blob)
        #expect(await restored.currentIdentity() == identity)
        #expect(try await restored.messages(in: chat.id).first?.body == .text("keep me"))
        await #expect(throws: KhensuError.invalidState) { try await restored.importState(Data("{}".utf8)) }

        await core.wipe()
        #expect(await core.currentIdentity() == nil)
        #expect(await core.conversations().isEmpty)
    }

    @Test("Connecting to a devnet reports its endpoints")
    func connect() async throws {
        let (core, _, _) = try await newCore()
        let config = try DevnetConfig(string: #"{"name":"local","nodes":["quic://127.0.0.1:4433","quic://127.0.0.1:4434"]}"#)
        let state = try await core.connect(config)
        #expect(state == .connected(network: "local (simulated)", nodes: 2))
        await core.disconnect()
        #expect(await core.connectionState() == .offline)
    }

    @Test("A directory v2 counts leases, reads the rules and feeds the network status")
    func directoryV2() async throws {
        let v2 = #"{"version":2,"network":"devnet","genesis_time":1791504000,"epoch_secs":3600,"rules":{"committee_size":6,"threshold":5,"mailbox_replicas":2,"founder_pk":"x"},"header":"AAAA","leases":["a","b","c","d","e","f"]}"#
        let config = try DevnetConfig(string: v2)
        #expect(config.version == 2 && config.nodeCount == 6 && config.endpoints.isEmpty)
        #expect(config.rules["committee_size"] == 6 && config.rules["founder_pk"] == nil)
        #expect(throws: KhensuError.invalidDevnetConfig("no leases in the directory")) {
            try DevnetConfig(string: #"{"version":2,"network":"devnet","header":"AAAA","leases":[]}"#)
        }
        #expect(throws: KhensuError.invalidDevnetConfig("no epoch header in the directory")) {
            try DevnetConfig(string: #"{"version":2,"network":"devnet","leases":["a"]}"#)
        }

        let (core, _, _) = try await newCore()
        #expect(await core.networkStatus() == nil)
        await core.setNetworkTest(.full)
        _ = try await core.connect(config)
        let status = try #require(await core.networkStatus())
        #expect(status.nodes == 6 && status.committee == 6 && status.mailboxReplicas == 2 && status.loopReturnRate == nil)
        await core.disconnect()
    }

    @Test("CoreLog keeps the last lines and streams new ones")
    func coreLog() async throws {
        let log = CoreLog(capacity: 3)
        let stream = log.stream()
        for i in 1...5 { log.append(level: .info, target: "t", message: "event.\(i)", fields: "n=\(i)") }
        #expect(log.snapshot().map(\.message) == ["event.3", "event.4", "event.5"])
        var it = stream.makeAsyncIterator()
        let first = try #require(await it.next())
        #expect(first.message == "event.1" && first.text.hasSuffix("info  event.1 n=1"))
        #expect(log.export().split(separator: "\n").count == 3)
        log.clear()
        #expect(log.snapshot().isEmpty)
    }

    @Test("The seeded core has sample chats for previews")
    func seeded() async throws {
        let core = await MockCore.seeded(timing: .instant)
        let list = await core.conversations()
        #expect(list.count >= 5)
        #expect(Set(list.map(\.kind)) == Set(ConversationKind.allCases))
        #expect(list.first?.isPinned == true)
    }
}
