// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import Network

/// Bonjour service for calls and live rooms between devices on the same
/// network or nearby over peer-to-peer Wi-Fi. No server sits in the middle.
enum CallService {
    static let type = "_khensu-call._tcp"

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true
        p.serviceClass = .interactiveVideo
        return p
    }
}

/// Packet types inside the encrypted channel.
enum CallPacket: UInt8 {
    case video = 1, audio = 2, videoFormat = 3, control = 4
}

/// Handshake, keys and per-direction AES-256-GCM.
///
/// The host makes a fresh ML-KEM-1024 key pair per call. The room ID is a
/// hash of its public key, so a guest who got the room ID through an
/// end-to-end encrypted chat knows it reached the right host. The guest
/// encapsulates to that key; both sides derive one key per direction with
/// HKDF-SHA512 over the transcript, and every frame is sealed under a
/// counter nonce that never repeats.
struct CallKeys: Sendable {
    let send: SymmetricKey
    let receive: SymmetricKey
    /// Six digits both people can read aloud to check nobody is in between.
    let safetyCode: String

    static func roomID(for publicKey: Data) -> String {
        let digest = Data(SHA256.hash(data: publicKey)).prefix(10)
        return Base32.encode(digest)
    }

    static func derive(shared: SymmetricKey, publicKey: Data, ciphertext: Data, isHost: Bool) -> CallKeys {
        let salt = Data(SHA512.hash(data: publicKey + ciphertext))
        func key(_ label: String) -> SymmetricKey {
            HKDF<SHA512>.deriveKey(inputKeyMaterial: shared, salt: salt, info: Data(label.utf8), outputByteCount: 32)
        }
        let h2g = key("khensu.nu call v1 host to guest")
        let g2h = key("khensu.nu call v1 guest to host")
        let n = (Int(salt[0]) << 16 | Int(salt[1]) << 8 | Int(salt[2])) % 1_000_000
        let code = String(format: "%03d %03d", n / 1000, n % 1000)
        return isHost ? CallKeys(send: h2g, receive: g2h, safetyCode: code)
                      : CallKeys(send: g2h, receive: h2g, safetyCode: code)
    }
}

enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    static func encode(_ data: Data) -> String {
        var out = ""
        var buffer = 0
        var bits = 0
        for b in data {
            buffer = buffer << 8 | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }
}

/// One TCP connection with length-prefixed frames. The first two frames are
/// the plaintext handshake; everything after is sealed with `CallKeys`.
/// All work runs on the wire's serial queue, so nonce order is send order.
final class CallWire: @unchecked Sendable {
    let connection: NWConnection
    let queue = DispatchQueue(label: "nu.khensu.call.wire", qos: .userInteractive)

    var onFrame: (@Sendable (Data) -> Void)?
    var onClose: (@Sendable () -> Void)?
    var onReady: (@Sendable () -> Void)?

    private var keys: CallKeys?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var pending = 0
    private var closed = false
    private let lock = NSLock()

    /// Sent before anything else once the connection is up: the relay's
    /// header line (`CallRelay`), or nothing for a direct connection.
    private let preamble: Data?

    init(_ connection: NWConnection, preamble: Data? = nil) {
        self.connection = connection
        self.preamble = preamble
    }

    /// Bytes handed to the network that haven't left this device yet.
    var pendingBytes: Int { lock.withLock { pending } }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = self.preamble { self.connection.send(content: p, completion: .idempotent) }
                self.onReady?()
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        readLength()
    }

    /// Must run on `queue`, so the very next frame is already sealed.
    func setKeysNow(_ k: CallKeys) {
        dispatchPrecondition(condition: .onQueue(queue))
        keys = k
    }

    func close() {
        queue.async {
            self.connection.cancel()
            self.finish()
        }
    }

    // MARK: Sending

    func sendPlain(_ body: Data) {
        queue.async { self.write(body) }
    }

    func send(_ type: CallPacket, _ body: Data) {
        queue.async {
            guard let keys = self.keys else { return }
            var plain = Data([type.rawValue])
            plain.append(body)
            guard let sealed = try? AES.GCM.seal(plain, using: keys.send, nonce: Self.nonce(self.sendCounter)) else { return }
            self.sendCounter += 1
            self.write(sealed.ciphertext + sealed.tag)
        }
    }

    private func write(_ body: Data) {
        var frame = Data(count: 4)
        let n = UInt32(body.count).bigEndian
        withUnsafeBytes(of: n) { frame.replaceSubrange(0..<4, with: $0) }
        frame.append(body)
        let size = frame.count
        lock.withLock { pending += size }
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.pending -= size }
        })
    }

    // MARK: Receiving

    private func readLength() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, done, error in
            guard let self else { return }
            guard let data, data.count == 4, error == nil else { return self.finish() }
            let n = data.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard n > 0, n < 8 << 20 else { return self.finish() }
            self.readBody(n)
            if done { self.finish() }
        }
    }

    private func readBody(_ n: Int) {
        connection.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == n, error == nil else { return self.finish() }
            self.deliver(data)
            self.readLength()
        }
    }

    private func deliver(_ frame: Data) {
        guard let keys else { return onFrame?(frame) ?? () }
        guard frame.count > 16,
              let box = try? AES.GCM.SealedBox(nonce: Self.nonce(receiveCounter), ciphertext: frame.dropLast(16), tag: frame.suffix(16)),
              let plain = try? AES.GCM.open(box, using: keys.receive)
        else { return finish() }
        receiveCounter += 1
        onFrame?(plain)
    }

    private func finish() {
        let fire: Bool = lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
        if fire {
            connection.cancel()
            onClose?()
        }
    }

    private static func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
        var bytes = Data(count: 12)
        withUnsafeBytes(of: counter.bigEndian) { bytes.replaceSubrange(4..<12, with: $0) }
        return try! AES.GCM.Nonce(data: bytes)
    }
}

/// Little helpers for packing media headers.
extension Data {
    mutating func appendInt64(_ v: Int64) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt16(_ v: UInt16) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }

    func int64(at i: Int) -> Int64 {
        var v: Int64 = 0
        for k in 0..<8 { v = v << 8 | Int64(self[startIndex + i + k]) }
        return v
    }

    func uint16(at i: Int) -> Int {
        Int(self[startIndex + i]) << 8 | Int(self[startIndex + i + 1])
    }
}
