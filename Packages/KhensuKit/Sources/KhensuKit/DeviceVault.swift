// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Device-held keys (PLAN.md, "On-device biometrics"; PROTOCOL.md 3.2):
///
/// - The identity device key is an ML-DSA-87 key created inside the Secure
///   Enclave, non-exportable, usable only after Face ID or Touch ID with the
///   currently enrolled biometrics (`.biometryCurrentSet`).
/// - The local store key is a random AES-256 key wrapped by a Secure Enclave
///   ML-KEM-1024 key. Unwrapping it is the app unlock: the wrap key's access
///   control asks for Face ID with passcode fallback, passcode only (coercion
///   setting), or nothing when app lock is off. The key is dropped from memory
///   when the app locks.
///
/// Without a Secure Enclave (Simulator, tests) the same keys are software keys
/// kept in the keychain, and `hardware` says so in Settings › About.
public final class DeviceVault: @unchecked Sendable {
    public enum Hardware: String, Sendable { case secureEnclave = "Secure Enclave", software = "Software (no Secure Enclave)" }

    public enum UnlockPolicy: String, Sendable, Codable, CaseIterable {
        /// Face ID or Touch ID, device passcode as fallback.
        case biometricsOrPasscode
        /// Device passcode only: a face can be forced, a passcode can't.
        case passcodeOnly
        /// App lock off: the store key opens without a prompt.
        case none
    }

    private enum Item {
        static let identityKey = "identity.mldsa87"
        static let wrapKey = "store.wrap.mlkem1024"
        static let wrapPolicy = "store.wrap.policy"
        static let wrappedStoreKey = "store.key.wrapped"
    }

    public let hardware: Hardware
    private let store: any SecretStore
    private let lock = NSLock()
    private var storeKey: SymmetricKey?

    /// Whether software keys still ask LocalAuthentication before unlocking.
    /// Secure Enclave keys always enforce their access control in hardware.
    private let softwareKeysAuthenticate: Bool

    public init(store: any SecretStore, allowSecureEnclave: Bool = true, softwareKeysAuthenticate: Bool = true) {
        self.store = store
        self.softwareKeysAuthenticate = softwareKeysAuthenticate
        #if targetEnvironment(simulator)
        // The iOS 26 Simulator reports `SecureEnclave.isAvailable` but rejects
        // post-quantum Secure Enclave keys (LocalAuthentication error -1020).
        self.hardware = .software
        #else
        self.hardware = allowSecureEnclave && SecureEnclave.isAvailable ? .secureEnclave : .software
        #endif
    }

    // MARK: Identity key

    /// Creates the identity device key and returns its ML-DSA-87 public key.
    public func createIdentityKey() throws -> Data {
        guard try store.read(Item.identityKey) == nil else { throw KhensuError.identityExists }
        switch hardware {
        case .secureEnclave:
            let key: SecureEnclave.MLDSA87.PrivateKey
            do {
                key = try SecureEnclave.MLDSA87.PrivateKey(accessControl: Self.accessControl([.privateKeyUsage, .biometryCurrentSet]))
            } catch {
                // No biometrics enrolled: fall back to user presence (passcode).
                key = try SecureEnclave.MLDSA87.PrivateKey(accessControl: Self.accessControl([.privateKeyUsage, .userPresence]))
            }
            try store.write(Item.identityKey, Data([1]) + key.dataRepresentation)
            return key.publicKey.rawRepresentation
        case .software:
            let key = try MLDSA87.PrivateKey()
            try store.write(Item.identityKey, Data([0]) + key.integrityCheckedRepresentation)
            return key.publicKey.rawRepresentation
        }
    }

    public func identityPublicKey() throws -> Data? {
        guard let blob = try store.read(Item.identityKey), let tag = blob.first else { return nil }
        let rest = blob.dropFirst()
        return tag == 1
            ? try SecureEnclave.MLDSA87.PrivateKey(dataRepresentation: rest).publicKey.rawRepresentation
            : try MLDSA87.PrivateKey(integrityCheckedRepresentation: rest).publicKey.rawRepresentation
    }

    /// `Sign(identity_sk, label, content)` (PROTOCOL.md section 1). Prompts for Face ID on hardware keys.
    public func signWithIdentity(label: String, content: Data, reason: String) async throws -> Data {
        guard let blob = try store.read(Item.identityKey), let tag = blob.first else { throw KhensuError.noIdentity }
        let message = IdentityCrypto.vector(IdentityCrypto.label(label)) + IdentityCrypto.vector(content)
        if tag == 1 {
            let context = LAContext()
            context.localizedReason = reason
            let key = try SecureEnclave.MLDSA87.PrivateKey(dataRepresentation: blob.dropFirst(), authenticationContext: context)
            return try key.signature(for: message)
        }
        return try MLDSA87.PrivateKey(integrityCheckedRepresentation: blob.dropFirst()).signature(for: message)
    }

    // MARK: Local store key

    public var hasStoreKey: Bool { (try? store.read(Item.wrappedStoreKey)) != nil }

    public var isUnlocked: Bool { lock.withLock { storeKey != nil } }

    public func currentPolicy() -> UnlockPolicy {
        (try? store.read(Item.wrapPolicy)).flatMap { UnlockPolicy(rawValue: String(decoding: $0, as: UTF8.self)) } ?? .biometricsOrPasscode
    }

    /// Generates the local store key, wraps it under `policy`, and leaves the vault unlocked.
    public func createStoreKey(policy: UnlockPolicy) throws {
        guard !hasStoreKey else { throw KhensuError.identityExists }
        let key = SymmetricKey(size: .bits256)
        try wrap(key, policy: policy)
        lock.withLock { storeKey = key }
    }

    /// The app unlock. Shows Face ID (or the passcode sheet) unless app lock is off.
    public func unlock(reason: String) async throws {
        if isUnlocked { return }
        guard let wrapped = try store.read(Item.wrappedStoreKey),
              let wrapKey = try store.read(Item.wrapKey),
              let tag = wrapKey.first
        else { throw KhensuError.noIdentity }
        let policy = currentPolicy()
        let context = LAContext()
        context.localizedReason = reason
        let authenticate = tag == 1 || softwareKeysAuthenticate
        if authenticate && (policy == .biometricsOrPasscode || (policy == .passcodeOnly && tag == 0)) {
            var error: NSError?
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } else if tag == 1 {
                throw error ?? KhensuError.invalidState
            }
            // Software keys on a Simulator without a passcode: nothing to evaluate.
        }
        let encapsulated = wrapped.prefix(MLKEM1024.encapsulatedSize)
        let sealed = wrapped.dropFirst(MLKEM1024.encapsulatedSize)
        let shared: SymmetricKey = tag == 1
            ? try SecureEnclave.MLKEM1024.PrivateKey(dataRepresentation: wrapKey.dropFirst(), authenticationContext: context).decapsulate(encapsulated)
            : try MLKEM1024.PrivateKey(integrityCheckedRepresentation: wrapKey.dropFirst()).decapsulate(encapsulated)
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: Self.kek(shared))
        lock.withLock { storeKey = SymmetricKey(data: raw) }
    }

    /// Drops the store key from memory.
    public func lockNow() { lock.withLock { storeKey = nil } }

    /// Re-wraps the (unlocked) store key under a new policy, with a new wrap key.
    public func changePolicy(_ policy: UnlockPolicy) throws {
        guard let key = lock.withLock({ storeKey }) else { throw KhensuError.invalidState }
        try wrap(key, policy: policy)
    }

    public func seal(_ plaintext: Data) throws -> Data {
        guard let key = lock.withLock({ storeKey }) else { throw KhensuError.invalidState }
        return try AES.GCM.seal(plaintext, using: key, authenticating: IdentityCrypto.label("local store")).combined!
    }

    public func open(_ ciphertext: Data) throws -> Data {
        guard let key = lock.withLock({ storeKey }) else { throw KhensuError.invalidState }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: IdentityCrypto.label("local store"))
    }

    /// Crypto-erase: delete the wrap key, the wrapped store key and the identity key.
    public func wipe() throws {
        lockNow()
        for item in [Item.wrapKey, Item.wrappedStoreKey, Item.wrapPolicy, Item.identityKey] {
            try store.delete(item)
        }
    }

    // MARK: Private

    private func wrap(_ key: SymmetricKey, policy: UnlockPolicy) throws {
        let flags: SecAccessControlCreateFlags = switch policy {
        case .biometricsOrPasscode: [.privateKeyUsage, .userPresence]
        case .passcodeOnly: [.privateKeyUsage, .devicePasscode]
        case .none: [.privateKeyUsage]
        }
        let wrapBlob: Data
        let result: KEM.EncapsulationResult
        switch hardware {
        case .secureEnclave:
            let wrapKey = try SecureEnclave.MLKEM1024.PrivateKey(accessControl: Self.accessControl(flags))
            result = try wrapKey.publicKey.encapsulate()
            wrapBlob = Data([1]) + wrapKey.dataRepresentation
        case .software:
            let wrapKey = try MLKEM1024.PrivateKey()
            result = try wrapKey.publicKey.encapsulate()
            wrapBlob = Data([0]) + wrapKey.integrityCheckedRepresentation
        }
        let raw = key.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(raw, using: Self.kek(result.sharedSecret)).combined!
        try store.write(Item.wrapKey, wrapBlob)
        try store.write(Item.wrappedStoreKey, result.encapsulated + sealed)
        try store.write(Item.wrapPolicy, Data(policy.rawValue.utf8))
    }

    private static func kek(_ shared: SymmetricKey) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: shared, info: IdentityCrypto.label("store key wrap"), outputByteCount: 32)
    }

    private static func accessControl(_ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw error!.takeRetainedValue() as any Error
        }
        return ac
    }
}

extension MLKEM1024 {
    /// FIPS 203 ciphertext size for ML-KEM-1024.
    static let encapsulatedSize = 1568
}
