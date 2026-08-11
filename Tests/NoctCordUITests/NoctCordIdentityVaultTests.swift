import CryptoKit
import Foundation
import NoctCordCore
@testable import NoctCordUI
@preconcurrency import NoctweaveCore
import XCTest

final class NoctCordIdentityVaultTests: XCTestCase {
    func testVaultEncryptsAndReusesPortableAndIsolatedKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-identity-vault-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("identities.vault")
        let encryptionKey = SymmetricKey(data: Data(repeating: 0x73, count: 32))
        let firstVault = NoctCordIdentityVault(
            fileURL: fileURL,
            encryptionKey: encryptionKey
        )
        let firstSpace = UUID()
        let secondSpace = UUID()
        let firstMember = handle(0x11)
        let secondMember = handle(0x12)
        let portableOne = try await firstVault.binding(
            scope: .portable,
            displayName: "Luna",
            spaceID: firstSpace,
            memberHandle: firstMember
        )
        let portableTwo = try await firstVault.binding(
            scope: .portable,
            displayName: "Luna",
            spaceID: secondSpace,
            memberHandle: secondMember
        )
        let isolatedOne = try await firstVault.binding(
            scope: .isolated,
            displayName: "Luna",
            spaceID: firstSpace,
            memberHandle: firstMember
        )

        XCTAssertEqual(portableOne.profile.identityID, portableTwo.profile.identityID)
        XCTAssertNotEqual(portableOne.profile.identityID, isolatedOne.profile.identityID)
        let storedBytes = try Data(contentsOf: fileURL)
        XCTAssertNil(String(data: storedBytes, encoding: .utf8)?.range(of: "Luna"))
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[
            .posixPermissions
        ] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        let reopenedVault = NoctCordIdentityVault(
            fileURL: fileURL,
            encryptionKey: encryptionKey
        )
        let isolatedAgain = try await reopenedVault.binding(
            scope: .isolated,
            displayName: "Luna",
            spaceID: firstSpace,
            memberHandle: firstMember
        )
        XCTAssertEqual(isolatedOne.profile.identityID, isolatedAgain.profile.identityID)
        XCTAssertTrue(try isolatedAgain.verify())
    }

    private func handle(_ byte: UInt8) -> GroupScopedMemberHandleV2 {
        GroupScopedMemberHandleV2(
            rawValue: Data(repeating: byte, count: 32).base64EncodedString()
        )
    }
}
