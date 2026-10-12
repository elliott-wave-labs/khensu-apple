// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import KhensuKit
import Observation
import os

enum AppTab: String, Hashable, CaseIterable {
    case chats, feed, calls, search, settings
}

/// App state and the bridge between SwiftUI and the core. Everything the core
/// returns is plaintext, so it lives here only while the app is unlocked:
/// `lock()` persists sealed state and drops it all from memory.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case loading, onboarding, locked, ready }

    private(set) var phase: Phase = .loading
    private(set) var identity: Identity?
    private(set) var conversations: [Conversation] = []
    private(set) var connection: ConnectionState = .offline
    private(set) var devnet: DevnetConfig?
    /// Network test: the core's counters, the last loop RTTs and recent header/receipt events.
    private(set) var network: NetworkStatus?
    private(set) var loopSamples: [LoopSample] = []
    private(set) var networkEvents: [NetworkEventRecord] = []
    var networkTest = NetworkTestOptions.off {
        didSet { Task { await core.setNetworkTest(networkTest) } }
    }
    private(set) var sharedDrafts: [String] = []
    var selectedTab: AppTab = .chats
    var selectedConversation: ConversationID?
    var errorMessage: String?
    /// The call or live room on screen, if any.
    var activeCall: CallSession?

    let core: any KhensuCore
    let vault: DeviceVault
    let launch: LaunchOptions
    private let stateURL: URL
    private var eventTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    private let log = Logger(subsystem: "nu.khensu.ptah", category: "app")

    init(core: any KhensuCore, vault: DeviceVault, stateURL: URL, launch: LaunchOptions) {
        self.core = core
        self.vault = vault
        self.stateURL = stateURL
        self.launch = launch
        if let tab = launch.tab { selectedTab = tab }
    }

    static func live() -> AppModel {
        let launch = LaunchOptions.current
        if launch.demo {
            // Screenshots and previews: seeded MockCore, software keys, no lock.
            return AppModel(core: MockCore(), vault: DeviceVault(store: MemorySecretStore(), allowSecureEnclave: false),
                            stateURL: FileManager.default.temporaryDirectory.appendingPathComponent("demo.sealed"), launch: launch)
        }
        let support = URL.applicationSupportDirectory.appendingPathComponent("khensu", isDirectory: true)
        return AppModel(core: CoreFactory.make(), vault: DeviceVault(store: KeychainStore()),
                        stateURL: support.appendingPathComponent("state.sealed"), launch: launch)
    }

    var appLockPolicy: DeviceVault.UnlockPolicy { vault.currentPolicy() }

    /// The name shown to the other person in a call or live room.
    var callName: String { identity?.displayName ?? "khensu.ñü" }

    // MARK: Lifecycle

    func start() async {
        guard phase == .loading else { return }
        if launch.demo {
            if launch.screen == .onboarding {
                phase = .onboarding
                return
            }
            if let seeded = core as? MockCore { await seeded.seedForDemo() }
            try? vault.createStoreKey(policy: .none)
            if launch.screen == .lock {
                phase = .locked
                return
            }
            await didUnlock()
            if launch.screen == .networkTest,
               let demo = try? DevnetConfig(string: #"{"version":2,"network":"devnet","rules":{"committee_size":6,"threshold":5,"mailbox_replicas":2},"header":"-","leases":["1","2","3","4","5","6"]}"#) {
                // The simulated network answers loops and receipts for the screenshot.
                networkTest = .full
                await connect(demo)
            }
            return
        }
        if vault.hasStoreKey {
            phase = .locked
            if appLockPolicy == .none { await unlock() }
        } else {
            phase = .onboarding
        }
        if let devnetPath = launch.devnet {
            await autoDevnet(devnetPath)
        }
    }

    /// `-KhensuDevnet <path|auto>`: a test identity without app lock if there is
    /// none, then connect to that devnet.json with loops and receipts on and
    /// open the Network test screen. For running against khensu-devnet from
    /// the command line; `auto` reads ../khensu-devnet/devnet.json next to this
    /// repo (Simulator and Mac builds), a relative path is taken from the app's
    /// Documents (devices).
    private func autoDevnet(_ path: String) async {
        if phase == .onboarding {
            do {
                _ = try await createIdentity(displayName: "Tester", handle: "", appLock: false)
                await finishOnboarding()
            } catch {
                errorMessage = "Auto devnet: \(error.localizedDescription)"
                return
            }
        }
        guard phase == .ready else { return }
        let url = switch path {
        case "auto": URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../khensu-devnet/devnet.json").standardizedFileURL
        case let p where p.hasPrefix("/"): URL(fileURLWithPath: p)
        // On a device: a file copied into the app's Documents with `devicectl device copy to`.
        default: URL.documentsDirectory.appendingPathComponent(path)
        }
        do {
            let config = try DevnetConfig(json: Data(contentsOf: url))
            networkTest = .full
            selectedTab = .settings
            await connect(config)
            log.info("auto devnet: \(self.connection.summary, privacy: .public)")
        } catch {
            errorMessage = "Auto devnet: \(error.localizedDescription)"
        }
    }

    func unlock() async {
        do {
            try await vault.unlock(reason: "Unlock your messages")
            if FileManager.default.fileExists(atPath: stateURL.path) {
                try await core.importState(vault.open(Data(contentsOf: stateURL)))
            }
            await didUnlock()
        } catch {
            log.error("unlock failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func didUnlock() async {
        identity = await core.currentIdentity()
        guard identity != nil else {
            phase = .onboarding
            return
        }
        startEvents()
        await drainIncoming()
        await refresh()
        connection = await core.connectionState()
        loadSharedDrafts()
        phase = .ready
    }

    /// Persist, drop plaintext from memory, forget the store key.
    func lock() async {
        guard phase == .ready, vault.currentPolicy() != .none else { return }
        await persist()
        eventTask?.cancel()
        eventTask = nil
        await core.wipe()
        vault.lockNow()
        conversations = []
        identity = nil
        selectedConversation = nil
        phase = .locked
    }

    func didEnterBackground() async {
        backgroundedAt = .now
        await persist()
    }

    func didBecomeActive() async {
        defer { backgroundedAt = nil }
        if phase == .ready, let since = backgroundedAt, Date.now.timeIntervalSince(since) >= Double(gracePeriodSeconds) {
            await lock()
        }
        if phase == .ready {
            await drainIncoming()
            loadSharedDrafts()
        }
    }

    var gracePeriodSeconds: Int {
        UserDefaults.standard.object(forKey: SettingsKey.gracePeriod) as? Int ?? 60
    }

    func persist() async {
        guard vault.isUnlocked, !launch.demo else { return }
        do {
            let sealed = try vault.seal(await core.exportState())
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: stateURL, options: [.atomic, .completeFileProtection])
            var url = stateURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            log.error("persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Onboarding

    /// Creates the device keys and the identity; returns the recovery phrase to show once.
    func createIdentity(displayName: String, handle: String, appLock: Bool) async throws -> [String] {
        let h: Handle? = handle.isEmpty ? nil : try Handle(handle)
        let key = try vault.identityPublicKey() ?? vault.createIdentityKey()
        if !vault.hasStoreKey { try vault.createStoreKey(policy: appLock ? .biometricsOrPasscode : .none) }
        let new = try await core.createIdentity(displayName: displayName, handle: h, identityKey: key)
        identity = new.identity
        await persist()
        return new.recoveryPhrase
    }

    func finishOnboarding() async {
        await didUnlock()
    }

    // MARK: Conversations

    func refresh() async {
        do { conversations = try await core.conversations() } catch { errorMessage = error.localizedDescription }
    }

    func conversation(_ id: ConversationID?) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func apply(_ change: ConversationChange, to id: ConversationID) {
        Task {
            do { try await core.update(id, change) } catch { errorMessage = error.localizedDescription }
            await refresh()
        }
    }

    func send(_ message: OutgoingMessage, to id: ConversationID) async {
        do {
            _ = try await core.send(message, to: id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addContact(_ invite: ContactInvite) async throws -> Conversation {
        let c = try await core.addContact(invite)
        await refresh()
        await persist()
        return c
    }

    // MARK: Network

    func connect(_ config: DevnetConfig) async {
        devnet = config
        do { connection = try await core.connect(config) } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        await core.disconnect()
        connection = .offline
    }

    func refreshNetworkStatus() async {
        network = await core.networkStatus()
    }

    func clearNetworkTest() {
        loopSamples = []
        networkEvents = []
        CoreLog.shared.clear()
    }

    private func record(_ event: NetworkEvent) {
        switch event {
        case .loopReturned(let rtt, let hops):
            loopSamples.append(LoopSample(at: .now, rttMs: rtt, hops: hops))
            if loopSamples.count > 120 { loopSamples.removeFirst(loopSamples.count - 120) }
        case .headerAccepted, .storeReceipt:
            networkEvents.insert(NetworkEventRecord(at: .now, event: event), at: 0)
            if networkEvents.count > 100 { networkEvents.removeLast(networkEvents.count - 100) }
        }
    }

    // MARK: Security

    func setAppLock(_ policy: DeviceVault.UnlockPolicy) {
        do { try vault.changePolicy(policy) } catch { errorMessage = error.localizedDescription }
    }

    /// Crypto-erase: delete the wrap key, identity key and sealed state, then return to onboarding.
    func panicWipe() async {
        eventTask?.cancel()
        await core.wipe()
        try? vault.wipe()
        try? FileManager.default.removeItem(at: stateURL)
        _ = try? IncomingQueue.shared()?.drain()
        conversations = []
        identity = nil
        selectedConversation = nil
        phase = .onboarding
    }

    // MARK: Shared items and incoming packets

    func loadSharedDrafts() {
        sharedDrafts = (try? SharedDrafts.shared()?.peek()) ?? []
    }

    func sendSharedDrafts(to id: ConversationID) async {
        guard let drafts = try? SharedDrafts.shared()?.take() else { return }
        sharedDrafts = []
        for d in drafts { await send(.text(d), to: id) }
    }

    func discardSharedDrafts() {
        _ = try? SharedDrafts.shared()?.take()
        sharedDrafts = []
    }

    private func drainIncoming() async {
        guard let queue = IncomingQueue.shared(), let packets = try? queue.drain(), !packets.isEmpty else { return }
        _ = try? await core.receive(sealed: packets)
    }

    private func startEvents() {
        eventTask?.cancel()
        let core = self.core
        eventTask = Task { [weak self] in
            for await event in await core.events() {
                guard let self else { return }
                switch event {
                case .connection(let state): self.connection = state
                case .conversationsChanged, .messageReceived, .messageStateChanged: await self.refresh()
                case .network(let e): self.record(e)
                }
            }
        }
    }
}

/// One loop probe that came back.
struct LoopSample: Identifiable, Hashable {
    let id = UUID()
    let at: Date
    let rttMs: UInt64
    let hops: Int
}

/// A header or receipt event, newest first on the Network test screen.
struct NetworkEventRecord: Identifiable, Hashable {
    let id = UUID()
    let at: Date
    let event: NetworkEvent

    var title: String {
        switch event {
        case .headerAccepted(let epoch, let nodes, let committee): "Header \(epoch) accepted: \(nodes) nodes, committee of \(committee)"
        case .storeReceipt(let replica, let epoch, let valid): valid ? "Store receipt from \(replica), epoch \(epoch)" : "Bad store receipt from \(replica)"
        case .loopReturned(let rtt, let hops): "Loop returned in \(rtt) ms over \(hops) hops"
        }
    }

    var symbol: String {
        switch event {
        case .headerAccepted: "checkmark.seal"
        case .storeReceipt(_, _, let valid): valid ? "tray.and.arrow.down" : "exclamationmark.triangle"
        case .loopReturned: "arrow.triangle.2.circlepath"
        }
    }
}

enum SettingsKey {
    static let gracePeriod = "appLock.gracePeriod"
    static let notificationMode = "notifications.mode"
    static let typingIndicators = "privacy.typingIndicators"
    static let readReceipts = "privacy.readReceipts"
}

/// Launch arguments for screenshots and UI checks, e.g. `-KhensuDemo YES -KhensuTab feed`.
struct LaunchOptions {
    enum Screen: String { case onboarding, lock, conversation, addContact, safety, devnet, networkTest, about }

    var demo = false
    var tab: AppTab?
    var screen: Screen?
    /// `-KhensuDevnet auto` or a path to a devnet.json: connect at launch (see `AppModel.autoDevnet`).
    var devnet: String?

    static var current: LaunchOptions {
        let d = UserDefaults.standard
        return LaunchOptions(
            demo: d.bool(forKey: "KhensuDemo"),
            tab: d.string(forKey: "KhensuTab").flatMap(AppTab.init(rawValue:)),
            screen: d.string(forKey: "KhensuScreen").flatMap(Screen.init(rawValue:)),
            devnet: d.string(forKey: "KhensuDevnet")
        )
    }
}
