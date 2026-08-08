import Foundation
import NoctCordCore
@testable import NoctCordUI
@preconcurrency import NoctweaveCore
import XCTest

final class NoctCordAttachmentTransferTests: XCTestCase {
    func testEncryptedAttachmentRoundTripAcrossRelay() async throws {
        let port = UInt16.random(in: 57_000...60_500)
        let endpoint = RelayEndpoint(host: "127.0.0.1", port: port)
        let server = RelayServer(store: RelayStore())
        try server.start(host: "127.0.0.1", port: port)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(180))

        let original = Data(String(repeating: "encrypted channel media\n", count: 5_000).utf8)
        let sanitized = NoctCordSanitizedAttachment(
            bytes: original,
            mimeType: "text/plain",
            kind: .document
        )
        let transfer = NoctCordAttachmentTransfer(relay: endpoint)
        let spaceID = UUID()
        let channelID = UUID()
        let uploaded = try await transfer.upload(
            sanitized,
            spaceID: spaceID,
            channelID: channelID,
            ttlSeconds: 600
        )

        XCTAssertTrue(uploaded.manifest.isStructurallyValid)
        XCTAssertEqual(uploaded.manifest.encryption.contentKey.count, 32)
        XCTAssertEqual(uploaded.manifest.digest.count, 32)
        XCTAssertNotEqual(
            uploaded.manifest.blobID,
            Data(original.prefix(uploaded.manifest.blobID.count))
        )

        let downloaded = try await transfer.download(
            manifest: uploaded.manifest,
            spaceID: spaceID,
            channelID: channelID
        )
        XCTAssertEqual(downloaded.id, uploaded.id)
        XCTAssertEqual(downloaded.bytes, original)
        XCTAssertEqual(downloaded.mediaType, "text/plain")
    }

    func testAttachmentCannotBeMovedToAnotherChannel() async throws {
        let port = UInt16.random(in: 60_501...62_500)
        let endpoint = RelayEndpoint(host: "127.0.0.1", port: port)
        let server = RelayServer(store: RelayStore())
        try server.start(host: "127.0.0.1", port: port)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(180))

        let transfer = NoctCordAttachmentTransfer(relay: endpoint)
        let spaceID = UUID()
        let uploaded = try await transfer.upload(
            NoctCordSanitizedAttachment(
                bytes: Data("bounded payload".utf8),
                mimeType: "text/plain",
                kind: .document
            ),
            spaceID: spaceID,
            channelID: UUID(),
            ttlSeconds: 600
        )

        do {
            _ = try await transfer.download(
                manifest: uploaded.manifest,
                spaceID: spaceID,
                channelID: UUID()
            )
            XCTFail("Cross-channel replay must fail authentication")
        } catch {
            XCTAssertEqual(
                error as? NoctCordAttachmentTransferError,
                .authenticationFailed
            )
        }
    }
}
