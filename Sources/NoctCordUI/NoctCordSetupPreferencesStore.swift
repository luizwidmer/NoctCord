import Foundation
import Security

/// Setup defaults contain relay addresses and a member name, so they belong in
/// device-local encrypted storage rather than a plaintext preferences plist.
struct NoctCordSetupPreferences: Codable, Equatable {
    var displayName = ""
    var relayAddress = ""
    var stunURL = ""
    var turnURL = ""
    var turnUsername = ""

    var isEmpty: Bool {
        displayName.isEmpty && relayAddress.isEmpty && stunURL.isEmpty
            && turnURL.isEmpty && turnUsername.isEmpty
    }
}

enum NoctCordSetupPreferencesError: LocalizedError {
    case unavailable
    case invalidRecord
    case legacySettingsPresent

    var errorDescription: String? {
        switch self {
        case .unavailable: "Protected setup settings are unavailable. Unlock Keychain access and try again."
        case .invalidRecord: "Protected setup settings could not be read. Existing settings were not replaced."
        case .legacySettingsPresent: "Older local setup settings are present. Record or export them, then use Purge and Reset App to remove them before saving new settings."
        }
    }
}

@MainActor
struct NoctCordSetupPreferencesStore {
    static let live = NoctCordSetupPreferencesStore()
    private static let legacyKeys = ["NoctCord.displayName", "NoctCord.relayAddress",
        "NoctCord.stunURL", "NoctCord.turnURL", "NoctCord.turnUsername"]
    private static let maximumBytes = 8 * 1_024

    let service: String
    let defaults: UserDefaults

    init(service: String = (Bundle.main.bundleIdentifier ?? "NoctCord") + ".setup.v1",
         defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "preferences",
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> NoctCordSetupPreferences {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(request as CFDictionary, &result) {
        case errSecSuccess:
            guard var data = result as? Data else { throw NoctCordSetupPreferencesError.invalidRecord }
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            guard !hasLegacyDefaults else { throw NoctCordSetupPreferencesError.legacySettingsPresent }
            guard data.count <= Self.maximumBytes,
                  let settings = try? JSONDecoder().decode(NoctCordSetupPreferences.self, from: data) else {
                throw NoctCordSetupPreferencesError.invalidRecord
            }
            return settings
        case errSecItemNotFound:
            guard !hasLegacyDefaults else { throw NoctCordSetupPreferencesError.legacySettingsPresent }
            return .init()
        default:
            throw NoctCordSetupPreferencesError.unavailable
        }
    }

    func save(_ settings: NoctCordSetupPreferences) throws {
        guard !hasLegacyDefaults else { throw NoctCordSetupPreferencesError.legacySettingsPresent }
        var data = try JSONEncoder().encode(settings)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        guard data.count <= Self.maximumBytes else { throw NoctCordSetupPreferencesError.invalidRecord }
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, update) }
        }
        guard status == errSecSuccess else { throw NoctCordSetupPreferencesError.unavailable }
    }

    func updateDisplayName(_ name: String) throws {
        var settings = try load()
        settings.displayName = name
        try save(settings)
    }

    func purge() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NoctCordSetupPreferencesError.unavailable
        }
        clearLegacyDefaults()
    }

    private func clearLegacyDefaults() {
        for key in Self.legacyKeys { defaults.removeObject(forKey: key) }
    }

    private var hasLegacyDefaults: Bool {
        Self.legacyKeys.contains { defaults.object(forKey: $0) != nil }
    }
}
