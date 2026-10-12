// SPDX-License-Identifier: AGPL-3.0-only

@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import Network
import Observation
#if os(iOS)
import UIKit
#endif

/// Messages that aren't media: effects, tips, mute state, keyframe requests.
struct CallControl: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case effect, tip, state, keyframe, viewers, bye }
    var kind: Kind
    var effect: CallEffect?
    var x: Double?
    var y: Double?
    var seed: UInt64?
    var from: String?
    var label: String?
    var muted: Bool?
    var cameraOff: Bool?
    var count: Int?
}

/// The adaptive ladder. Each step pairs an Opus audio rate with an HEVC
/// video rate; congestion takes video down first, then off, and only then
/// lowers the audio, so the voice never drops out.
enum CallLadder {
    struct Step: Sendable { let audio: Int; let video: Int }
    static let steps: [Step] = [
        Step(audio: 6_000, video: 0),
        Step(audio: 12_000, video: 0),
        Step(audio: 24_000, video: 0),
        Step(audio: 24_000, video: 150_000),
        Step(audio: 32_000, video: 300_000),
        Step(audio: 32_000, video: 600_000),
        Step(audio: 48_000, video: 1_200_000),
        Step(audio: 64_000, video: 2_500_000),
    ]
    static let start = 6
}

/// One person on the other end of a wire.
final class CallLink: @unchecked Sendable {
    let id = UUID().uuidString
    let wire: CallWire
    var name = ""
    var isViewer = false
    var ready = false

    init(_ wire: CallWire) { self.wire = wire }
}

/// Media routing that runs off the main thread: encoder output fans out to
/// every link, incoming media goes straight to the display layer and speaker.
final class CallPipe: @unchecked Sendable {
    let sink = CallVideoSink()
    let audio = CallAudio()
    let encoder = CallVideoEncoder()
    private let lock = NSLock()
    private var links: [CallLink] = []
    private var lastSets: [Data]?
    private var videoOn = true
    private var dropping = false
    private var videoRate = CallLadder.steps[CallLadder.start].video

    var allLinks: [CallLink] { lock.withLock { links } }
    var readyLinks: [CallLink] { lock.withLock { links.filter(\.ready) } }

    func add(_ l: CallLink) { lock.withLock { links.append(l) } }
    func remove(_ id: String) { lock.withLock { links.removeAll { $0.id == id } } }
    var backlog: Int { readyLinks.reduce(0) { $0 + $1.wire.pendingBytes } }

    func setStep(_ s: CallLadder.Step) {
        audio.setBitrate(s.audio)
        lock.withLock {
            videoOn = s.video > 0
            videoRate = s.video
        }
        if s.video > 0 { encoder.setBitrate(s.video) }
    }

    func setVideoEnabled(_ on: Bool) {
        lock.withLock { videoOn = on }
        if on { encoder.requestKeyframe() }
    }

    func wireUp() {
        encoder.onEncoded = { [weak self] key, pts, data, sets in
            guard let self else { return }
            let (on, rate) = self.lock.withLock { (self.videoOn, self.videoRate) }
            guard on else { return }
            // More than a second queued: skip video until the next keyframe.
            let behind = self.backlog > max(rate / 8, 64_000)
            let skip: Bool = self.lock.withLock {
                if behind { self.dropping = true }
                if self.dropping && key && !behind { self.dropping = false }
                return self.dropping
            }
            if skip {
                if !behind { self.encoder.requestKeyframe() }
                return
            }
            if let sets { self.lock.withLock { self.lastSets = sets }; self.broadcast(.videoFormat, Self.packFormat(sets)) }
            var body = Data([key ? 1 : 0])
            body.appendInt64(pts)
            body.append(data)
            self.broadcast(.video, body)
        }
        audio.onPacket = { [weak self] pts, data in
            var body = Data()
            body.appendInt64(pts)
            body.append(data)
            self?.broadcast(.audio, body)
        }
    }

    func broadcast(_ type: CallPacket, _ body: Data, except: String? = nil) {
        for l in readyLinks where l.id != except { l.wire.send(type, body) }
    }

    func send(_ control: CallControl, to link: CallLink? = nil, except: String? = nil) {
        guard let data = try? JSONEncoder().encode(control) else { return }
        if let link { link.wire.send(.control, data) } else { broadcast(.control, data, except: except) }
    }

    /// Media from a link. Returns a control message for the main thread, if any.
    func receive(_ plain: Data, from link: CallLink) -> CallControl? {
        guard let first = plain.first, let type = CallPacket(rawValue: first) else { return nil }
        let body = plain.dropFirst()
        switch type {
        case .video:
            guard body.count > 9 else { return nil }
            sink.enqueue(key: body[body.startIndex] == 1, pts: body.int64(at: 1), data: Data(body.dropFirst(9)))
        case .videoFormat:
            sink.setParameterSets(Self.unpackFormat(Data(body)))
        case .audio:
            guard body.count > 8 else { return nil }
            audio.play(Data(body.dropFirst(8)), from: link.id)
        case .control:
            return try? JSONDecoder().decode(CallControl.self, from: Data(body))
        }
        return nil
    }

    static func packFormat(_ sets: [Data]) -> Data {
        var d = Data([UInt8(sets.count)])
        for s in sets {
            d.appendUInt16(UInt16(s.count))
            d.append(s)
        }
        return d
    }

    static func unpackFormat(_ d: Data) -> [Data] {
        guard let n = d.first else { return [] }
        var out: [Data] = []
        var i = 1
        for _ in 0..<n {
            guard i + 2 <= d.count else { break }
            let len = d.uint16(at: i)
            i += 2
            guard i + len <= d.count else { break }
            out.append(d.subdata(in: d.startIndex + i..<d.startIndex + i + len))
            i += len
        }
        return out
    }
}

/// A 1-to-1 video call or a live room, end to end encrypted and sent
/// directly between devices.
@MainActor @Observable
final class CallSession: Identifiable {
    enum Mode: String, Sendable { case call, live }
    enum Role: Sendable { case host, guest, viewer }
    enum Phase: Equatable { case waiting, connecting, connected, ended(String?) }

    struct Peer: Identifiable, Equatable {
        let id: String
        var name: String
        var muted = false
        var cameraOff = false
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    nonisolated let id = UUID()
    let mode: Mode
    let role: Role
    let localName: String
    private(set) var roomID: String
    private(set) var phase: Phase = .waiting
    private(set) var safetyCode: String?
    private(set) var peers: [Peer] = []
    private(set) var viewerCount = 0
    private(set) var effects: [ActiveEffect] = []
    private(set) var toasts: [Toast] = []
    private(set) var connectedAt: Date?
    private(set) var step = CallLadder.start
    var muted = false { didSet { pipe.audio.muted = muted; announceState() } }
    var cameraOff = false { didSet { pipe.setVideoEnabled(!cameraOff); announceState() } }

    let camera: CallCamera?
    let pipe = CallPipe()
    private let gestures = GestureDetector()
    private var kem: MLKEM1024.PrivateKey?
    private var listener: NWListener?
    private var ticker: Task<Void, Never>?
    private var clearSince = Date()

    var isSending: Bool { role != .viewer }
    var audioRate: Int { CallLadder.steps[step].audio }
    var videoRate: Int { CallLadder.steps[step].video }

    // MARK: Start

    /// Host a call or a live room; the room ID goes to the other person
    /// through the encrypted chat.
    init(hosting mode: Mode, name: String) throws {
        let key = try MLKEM1024.PrivateKey()
        self.mode = mode
        self.role = .host
        self.localName = name
        self.kem = key
        self.roomID = CallKeys.roomID(for: key.publicKey.rawRepresentation)
        self.camera = CallCamera()
    }

    /// Join a room by ID, as a guest in a call or a viewer in a live room.
    init(joining roomID: String, mode: Mode, name: String) {
        self.mode = mode
        self.role = mode == .live ? .viewer : .guest
        self.localName = name
        self.roomID = roomID
        self.camera = mode == .live ? nil : CallCamera()
    }

    func start() {
        pipe.wireUp()
        pipe.setStep(CallLadder.steps[step])
        pipe.sink.onNeedKeyframe = { [weak self] in
            Task { @MainActor in self?.pipe.send(CallControl(kind: .keyframe)) }
        }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        if let camera {
            let encoder = pipe.encoder
            let gestures = gestures
            camera.onFrame = { [weak camera] sample in
                encoder.encode(sample)
                gestures.process(sample, mirrored: false)
                _ = camera
            }
            gestures.onGesture = { [weak self] effect, point in
                Task { @MainActor in self?.trigger(effect, at: point) }
            }
            camera.start()
        }
        pipe.audio.start(capture: isSending)
        switch role {
        case .host: listen()
        case .guest, .viewer: connect()
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    func end() {
        guard phase != .ended(nil) else { return }
        pipe.send(CallControl(kind: .bye))
        teardown(nil)
    }

    private func teardown(_ reason: String?) {
        ticker?.cancel()
        listener?.cancel()
        camera?.stop()
        pipe.encoder.stop()
        pipe.audio.stop()
        for l in pipe.allLinks { l.wire.close() }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        phase = .ended(reason)
    }

    // MARK: Hosting

    private func listen() {
        do {
            let l = try NWListener(using: CallService.parameters())
            let txt = NWTXTRecord(["n": localName, "m": mode.rawValue])
            l.service = NWListener.Service(name: roomID, type: CallService.type, domain: nil, txtRecord: txt)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let e) = state { Task { @MainActor in self?.teardown(e.localizedDescription) } }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            teardown(error.localizedDescription)
        }
    }

    private func accept(_ conn: NWConnection) {
        guard let kem else { return }
        if mode == .call, !pipe.allLinks.isEmpty { return conn.cancel() }
        let link = CallLink(CallWire(conn))
        let pk = kem.publicKey.rawRepresentation
        link.wire.onReady = { [wire = link.wire, name = localName, mode] in
            var hello = Data([1])
            hello.appendUInt16(UInt16(name.utf8.count))
            hello.append(Data(name.utf8))
            hello.append(mode == .live ? 1 : 0)
            hello.append(pk)
            wire.sendPlain(hello)
        }
        link.wire.onFrame = { [weak self, pipe] frame in
            if !link.ready {
                // Join: [2][role][name length][name][ML-KEM-1024 ciphertext]
                guard frame.count > 4 + 1568, frame.first == 2,
                      let shared = try? kem.decapsulate(frame.suffix(1568)) else { return link.wire.close() }
                let n = frame.uint16(at: 2)
                link.name = String(decoding: frame.dropFirst(4).prefix(n), as: UTF8.self)
                link.isViewer = frame[frame.startIndex + 1] == 1
                let keys = CallKeys.derive(shared: shared, publicKey: pk, ciphertext: Data(frame.suffix(1568)), isHost: true)
                link.wire.installKeys(keys)
                link.ready = true
                pipe.encoder.requestKeyframe()
                Task { @MainActor in self?.joined(link, code: keys.safetyCode) }
                return
            }
            if let c = pipe.receive(frame, from: link) {
                Task { @MainActor in self?.handle(c, from: link) }
            }
        }
        link.wire.onClose = { [weak self] in
            Task { @MainActor in self?.left(link) }
        }
        pipe.add(link)
        link.wire.start()
    }

    // MARK: Joining

    private func connect() {
        phase = .connecting
        let conn = NWConnection(to: .service(name: roomID, type: CallService.type, domain: "local.", interface: nil),
                                using: CallService.parameters())
        let link = CallLink(CallWire(conn))
        let room = roomID
        let viewer = role == .viewer
        let name = localName
        link.wire.onFrame = { [weak self, pipe] frame in
            if !link.ready {
                // Hello: [1][name length][name][mode][ML-KEM-1024 public key]
                guard frame.count > 4 + 1568, frame.first == 1 else { return link.wire.close() }
                let pk = Data(frame.suffix(1568))
                guard CallKeys.roomID(for: pk) == room,
                      let publicKey = try? MLKEM1024.PublicKey(rawRepresentation: pk),
                      let result = try? publicKey.encapsulate() else {
                    Task { @MainActor in self?.teardown("This call’s key doesn’t match its invitation.") }
                    return link.wire.close()
                }
                let n = frame.uint16(at: 1)
                link.name = String(decoding: frame.dropFirst(3).prefix(n), as: UTF8.self)
                var join = Data([2, viewer ? 1 : 0])
                join.appendUInt16(UInt16(name.utf8.count))
                join.append(Data(name.utf8))
                join.append(result.encapsulated)
                link.wire.sendPlain(join)
                let keys = CallKeys.derive(shared: result.sharedSecret, publicKey: pk, ciphertext: result.encapsulated, isHost: false)
                link.wire.installKeys(keys)
                link.ready = true
                pipe.encoder.requestKeyframe()
                Task { @MainActor in self?.joined(link, code: keys.safetyCode) }
                return
            }
            if let c = pipe.receive(frame, from: link) {
                Task { @MainActor in self?.handle(c, from: link) }
            }
        }
        link.wire.onClose = { [weak self] in
            Task { @MainActor in self?.left(link) }
        }
        pipe.add(link)
        link.wire.start()
    }

    // MARK: Peers

    private func joined(_ link: CallLink, code: String) {
        if link.isViewer {
            viewerCount += 1
            pipe.send(CallControl(kind: .viewers, count: viewerCount))
            toast("\(link.name.isEmpty ? "Someone" : link.name) is watching")
        } else {
            peers.append(Peer(id: link.id, name: link.name))
            safetyCode = code
        }
        if role == .viewer { safetyCode = code }
        if connectedAt == nil { connectedAt = .now }
        phase = .connected
        announceState()
    }

    private func left(_ link: CallLink) {
        pipe.remove(link.id)
        pipe.audio.remove(peer: link.id)
        guard phase != .ended(nil) else { return }
        if link.isViewer {
            viewerCount = max(0, viewerCount - 1)
            pipe.send(CallControl(kind: .viewers, count: viewerCount))
            return
        }
        peers.removeAll { $0.id == link.id }
        if role != .host || mode == .call {
            teardown(link.ready ? nil : "Couldn’t reach the call. Calls connect on the same network or nearby.")
        }
    }

    private func handle(_ c: CallControl, from link: CallLink) {
        switch c.kind {
        case .effect:
            guard let e = c.effect else { return }
            show(e, at: CGPoint(x: c.x ?? 0.5, y: c.y ?? 0.45), seed: c.seed ?? 1, from: c.from)
            // The host passes effects on, so every viewer, guest and cohost sees them.
            if role == .host { pipe.send(c, except: link.id) }
        case .tip:
            toast("\(c.from ?? "Someone") tipped \(c.label ?? "")")
            show(.heart, at: CGPoint(x: 0.5, y: 0.42), seed: c.seed ?? 7, from: c.from)
            if role == .host { pipe.send(c, except: link.id) }
        case .state:
            if let i = peers.firstIndex(where: { $0.id == link.id }) {
                peers[i].muted = c.muted ?? false
                peers[i].cameraOff = c.cameraOff ?? false
            }
        case .keyframe:
            pipe.encoder.requestKeyframe()
        case .viewers:
            viewerCount = c.count ?? viewerCount
        case .bye:
            link.wire.close()
        }
    }

    private func announceState() {
        pipe.send(CallControl(kind: .state, muted: muted, cameraOff: cameraOff))
    }

    // MARK: Effects and tips

    /// Sets off an effect here and on every other device in the room.
    func trigger(_ effect: CallEffect, at point: CGPoint = CGPoint(x: 0.5, y: 0.45)) {
        let seed = UInt64.random(in: 1...UInt64.max)
        let c = CallControl(kind: .effect, effect: effect, x: point.x, y: point.y, seed: seed, from: localName)
        pipe.send(c)
        show(effect, at: point, seed: seed, from: localName)
    }

    func sendTip(label: String) {
        let seed = UInt64.random(in: 1...UInt64.max)
        pipe.send(CallControl(kind: .tip, seed: seed, from: localName, label: label))
        toast("You tipped \(label)")
        show(.heart, at: CGPoint(x: 0.5, y: 0.42), seed: seed, from: localName)
    }

    private func show(_ kind: CallEffect, at p: CGPoint, seed: UInt64, from: String?) {
        let e = ActiveEffect(kind: kind, center: p, start: .now, seed: seed, from: from)
        effects.append(e)
        Task {
            try? await Task.sleep(for: .seconds(e.duration + 0.1))
            effects.removeAll { $0.id == e.id }
        }
    }

    private func toast(_ text: String) {
        let t = Toast(text: text)
        toasts.append(t)
        Task {
            try? await Task.sleep(for: .seconds(4))
            toasts.removeAll { $0.id == t.id }
        }
    }

    // MARK: Adaptive bitrate

    /// Twice a second: step down at once when more than a quarter second of
    /// media is queued, step up after four clear seconds.
    private func tick() {
        guard phase == .connected, isSending else { return }
        let s = CallLadder.steps[step]
        let backlog = pipe.backlog
        let budget = (s.audio + s.video) / 8 / 4
        if backlog > max(budget, 6_000), step > 0 {
            step -= 1
            clearSince = .now
            pipe.setStep(CallLadder.steps[step])
        } else if backlog < 2_000 {
            if Date.now.timeIntervalSince(clearSince) > 4, step < CallLadder.steps.count - 1 {
                step += 1
                clearSince = .now
                pipe.setStep(CallLadder.steps[step])
            }
        } else {
            clearSince = .now
        }
    }
}

extension CallWire {
    /// Switch to the sealed channel. Call from `onFrame`, which runs on the wire's queue.
    func installKeys(_ k: CallKeys) { setKeysNow(k) }
}
