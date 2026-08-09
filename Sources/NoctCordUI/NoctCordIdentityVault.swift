import CryptoKit
import Foundation
import NoctCordCore
@preconcurrency import NoctweaveCore
#if canImport(Security)
import Security
#endif

enum NoctCordIdentityVaultError: Error, LocalizedError {
    case unavailable
    case corrupted
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Secure local identity storage is unavailable on this device."
        case .corrupted:
            "The encrypted Noct Cord identity vault could not be verified."
        case .writeFailed:
            "Noct Cord could not save the encrypted identity vault."
        }
    }
}

/// Small application-owned vault for Noct Cord profile keys. Noctweave's
/// ClientState remains transport state; application identity material stays in
/// a separately encrypted file with a non-synchronizing Keychain key.
actor NoctCordIdentityVault {
    private static let maximumBytes = 2 * 1_024 * 1_024
    private static let aad = Data("org.noctcord.identity-vault/v1\0".utf8)
    private static let keychainService = "org.noctcord.identity-vault"

    private struct State: Codable {
        let version: Int
        var portableKey: NoctCordIdentityKeyV1?
        var isolatedKeys: [String: NoctCordIdentityKeyV1]

        static var empty: Self {
            State(version: 1, portableKey: nil, isolatedKeys: [:])
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let sealed: Data
    }

    private let fileURL: URL
    private let suppliedKey: SymmetricKey?

    init(fileURL: URL, encryptionKey: SymmetricKey? = nil) {
        self.fileURL = fileURL.standardizedFileURL
        suppliedKey = encryptionKey
    }

    func binding(
        scope: NoctCordIdentityScope,
        displayName: String,
        spaceID: UUID,
        memberHandle: GroupScopedMemberHandleV2,
        issuedAt: Date = Date()
    ) throws -> NoctCordCommunityIdentityBindingV1 {
        var state = try load()
        let key: NoctCordIdentityKeyV1
        switch scope {
        case .portable:
            if let existing = state.portableKey {
                key = existing
            } else {
                let generated = try NoctCordIdentityKeyV1.generate(scope: .portable)
                state.portableKey = generated
                key = generated
            }
        case .isolated:
            let identifier = spaceID.uuidString.lowercased()
            if let existing = state.isolatedKeys[identifier] {
                key = existing
            } else {
                let generated = try NoctCordIdentityKeyV1.generate(scope: .isolated)
                state.isolatedKeys[identifier] = generated
                key = generated
            }
        }
        let profile = try key.publicProfile(
            displayName: displayName,
            createdAt: issuedAt
        )
        let binding = try key.bind(
            profile: profile,
            to: spaceID,
            memberHandle: memberHandle,
            issuedAt: issuedAt
        )
        try save(state)
        return binding
    }

    private func load() throws -> State {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        let stored = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard stored.count <= Self.maximumBytes else {
            throw NoctCordIdentityVaultError.corrupted
        }
        do {
            let envelope = try NoctweaveCoder.decode(Envelope.self, from: stored)
            guard envelope.version == 1,
                  envelope.sealed.count <= Self.maximumBytes else {
                throw NoctCordIdentityVaultError.corrupted
            }
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            let plaintext = try AES.GCM.open(
                box,
                using: try encryptionKey(),
                authenticating: Self.aad
            )
            guard plaintext.count <= Self.maximumBytes else {
                throw NoctCordIdentityVaultError.corrupted
            }
            let state = try NoctweaveCoder.decode(State.self, from: plaintext)
            guard state.version == 1,
                  state.isolatedKeys.count <= 512 else {
                throw NoctCordIdentityVaultError.corrupted
            }
            return state
        } catch let error as NoctCordIdentityVaultError {
            throw error
        } catch {
            throw NoctCordIdentityVaultError.corrupted
        }
    }

    private func save(_ state: State) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let plaintext = try NoctweaveCoder.encode(state, sortedKeys: true)
            guard plaintext.count <= Self.maximumBytes else {
                throw NoctCordIdentityVaultError.writeFailed
            }
            let sealed = try AES.GCM.seal(
                plaintext,
                using: try encryptionKey(),
                authenticating: Self.aad
            )
            guard let combined = sealed.combined else {
                throw NoctCordIdentityVaultError.writeFailed
            }
            let bytes = try NoctweaveCoder.encode(
                Envelope(version: 1, sealed: combined),
                sortedKeys: true
            )
            try bytes.write(to: fileURL, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch let error as NoctCordIdentityVaultError {
            throw error
        } catch {
            throw NoctCordIdentityVaultError.writeFailed
        }
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let suppliedKey { return suppliedKey }
        #if canImport(Security)
        let account = Data(SHA256.hash(data: Data(fileURL.path.utf8))).base64EncodedString()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            throw NoctCordIdentityVaultError.unavailable
        }
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw NoctCordIdentityVaultError.unavailable
        }
        var add = query
        add.removeValue(forKey: kSecReturnData as String)
        add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecValueData as String] = bytes
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return try encryptionKey()
        }
        guard addStatus == errSecSuccess else {
            throw NoctCordIdentityVaultError.unavailable
        }
        return SymmetricKey(data: bytes)
        #else
        throw NoctCordIdentityVaultError.unavailable
        #endif
    }
}
