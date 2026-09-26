import Foundation
import Security
import XCTest
@testable import NoctCordUI

@MainActor
final class NoctCordSetupPreferencesStoreTests: XCTestCase {
    func testFullResetIntentHasNoPlaintextPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoctCord-ResetMarker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("reset.pending")
        try NoctCordSecureFileIO.writeAtomicPrivateFile(Data(), to: marker,
            maximumBytes: 0, allowEmpty: true)
        XCTAssertEqual(try Data(contentsOf: marker), Data())
    }

    func testProtectedRoundTripLeavesNoPlaintextPreferences() throws {
        let scope = UUID().uuidString
        let domain = "NoctCord.SetupPreferencesTests." + scope
        let service = domain + ".keychain"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        let store = NoctCordSetupPreferencesStore(service: service, defaults: defaults)
        defer {
            try? store.purge()
            defaults.removePersistentDomain(forName: domain)
        }
        let canary = "private-relay-" + scope
        let saved = NoctCordSetupPreferences(displayName: "Luna", relayAddress: canary,
            stunURL: "stun:stun.example.test", turnURL: "", turnUsername: "")
        try store.save(saved)
        XCTAssertNil(defaults.object(forKey: "NoctCord.displayName"))
        XCTAssertNil(defaults.object(forKey: "NoctCord.relayAddress"))
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains(canary) })

        let reopened = try NoctCordSetupPreferencesStore(service: service, defaults: defaults).load()
        XCTAssertEqual(reopened, saved)
        try store.updateDisplayName("Mara")
        XCTAssertEqual(try store.load().displayName, "Mara")
        XCTAssertEqual(try store.load().relayAddress, canary)
    }

    func testUnreadableProtectedRecordDoesNotDeleteLegacyValues() throws {
        let scope = UUID().uuidString
        let domain = "NoctCord.SetupPreferencesTests." + scope
        let service = domain + ".keychain"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        let store = NoctCordSetupPreferencesStore(service: service, defaults: defaults)
        defer {
            try? store.purge()
            defaults.removePersistentDomain(forName: domain)
        }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "preferences",
            kSecAttrSynchronizable as String: false, kSecValueData as String: Data("damaged".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        XCTAssertThrowsError(try store.load())
    }

    func testLegacySettingsBlockWritesUntilExplicitReset() throws {
        let scope = UUID().uuidString
        let domain = "NoctCord.SetupPreferencesTests." + scope
        let service = domain + ".keychain"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defaults.set("legacy-" + scope, forKey: "NoctCord.relayAddress")
        let store = NoctCordSetupPreferencesStore(service: service, defaults: defaults)
        defer {
            try? store.purge()
            defaults.removePersistentDomain(forName: domain)
        }
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.init(displayName: "New", relayAddress: "new.example.test")))
        XCTAssertEqual(defaults.string(forKey: "NoctCord.relayAddress"), "legacy-" + scope)
    }
}
