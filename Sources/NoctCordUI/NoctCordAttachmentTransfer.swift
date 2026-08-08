import CryptoKit
import Foundation
import NoctCordCore
@preconcurrency import NoctweaveCore

public enum NoctCordAttachmentTransferError: Error, Equatable, LocalizedError {
    case invalidContext
    case invalidManifest
    case expired
    case relayRejected
    case malformedRelayResponse
    case authenticationFailed
    case digestMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidContext:
            "The attachment does not belong to a valid channel context."
        case .invalidManifest:
            "The encrypted attachment manifest is invalid."
        case .expired:
            "The relay retention period for this attachment has expired."
        case .relayRejected:
            "The relay rejected part of the encrypted attachment."
        case .malformedRelayResponse:
            "The relay returned an invalid attachment response."
        case .authenticationFailed:
            "The attachment could not be authenticated and was not opened."
        case .digestMismatch:
            "The reconstructed attachment did not match its authenticated digest."
        }
    }
}

public struct NoctCordUploadedAttachment: Sendable {
    public let id: UUID
    public let manifest: NoctCordAttachmentManifestV1
    public let kind: NoctCordAttachmentKind
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let durationMilliseconds: UInt64?
}

public struct NoctCordDownloadedAttachment: Sendable {
    public let id: UUID
    public let bytes: Data
    public let mediaType: String
}

/// Encrypted relay-blob transport for Noct Cord channel attachments.
/// Source paths and filenames never leave the client. Every attachment gets a
/// fresh 256-bit key and every chunk is independently authenticated against its
/// space, channel, attachment, position, plaintext size, and retention date.
public actor NoctCordAttachmentTransfer {
    public static let chunkSize = 64 * 1_024
    public static let defaultTTLSeconds = 6 * 60 * 60
    public static let maximumTTLSeconds = Int(
        RealtimeRelayLimitsV1.maximumMediaRetentionSeconds
    )

    private let relayClient: RelayClient

    public init(
        relay: RelayEndpoint,
        accessPassword: String? = nil,
        policy: RelayClientPolicy = .default
    ) {
        relayClient = RelayClient(
            endpoint: relay,
            authToken: accessPassword,
            policy: policy
        )
    }

    public func upload(
        _ sanitized: NoctCordSanitizedAttachment,
        spaceID: UUID,
        channelID: UUID,
        ttlSeconds: Int = defaultTTLSeconds,
        now: Date = Date()
    ) async throws -> NoctCordUploadedAttachment {
        guard !sanitized.bytes.isEmpty,
              sanitized.bytes.count <= NoctCordAttachmentSanitizer.maximumBytes,
              (60...Self.maximumTTLSeconds).contains(ttlSeconds),
              now.timeIntervalSince1970.isFinite else {
            throw NoctCordAttachmentTransferError.invalidContext
        }

        let attachmentID = UUID()
        let blobCapability = OpaqueCapabilityV1.generate()
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let objectNonce = Data(AES.GCM.Nonce())
        let plaintextDigest = Data(SHA256.hash(data: sanitized.bytes))
        let chunks = sanitized.bytes.noctCordChunks(of: Self.chunkSize)

        let creation = try await relayClient.send(.createMediaBlobV1(
            MediaBlobCreateRequestV1(
                blobID: attachmentID,
                blobCapability: blobCapability,
                chunkCount: chunks.count,
                ttlSeconds: ttlSeconds
            )
        ))
        guard creation.error == nil else {
            throw NoctCordAttachmentTransferError.relayRejected
        }
        guard case .mediaBlobCreated(let created)? = creation.successBody,
              created.blobID == attachmentID,
              created.blobCapability == blobCapability,
              created.chunkCount == chunks.count else {
            throw NoctCordAttachmentTransferError.malformedRelayResponse
        }
        let expiresAt = created.expiresAt

        do {
            for (index, plaintext) in chunks.enumerated() {
                let aad = Self.authenticatedData(
                    spaceID: spaceID,
                    channelID: channelID,
                    attachmentID: attachmentID,
                    chunkIndex: index,
                    plaintextSize: sanitized.bytes.count,
                    expiresAt: expiresAt,
                    objectNonce: objectNonce
                )
                let payload = try CryptoBox.encrypt(
                    plaintext,
                    key: key,
                    authenticatedData: aad
                )
                let idempotencyKey = Self.idempotencyKey(
                    spaceID: spaceID,
                    channelID: channelID,
                    attachmentID: attachmentID,
                    chunkIndex: index,
                    payload: payload
                )
                let encodedPayload = Self.encode(payload)
                let request = MediaBlobUploadRequestV1(
                    blobID: attachmentID,
                    blobCapability: blobCapability,
                    chunkIndex: index,
                    payload: encodedPayload,
                    idempotencyKey: idempotencyKey
                )
                let response = try await relayClient.send(.uploadMediaBlobV1(request))
                guard response.error == nil else {
                    throw NoctCordAttachmentTransferError.relayRejected
                }
                guard case .mediaBlobChunk(let receipt)? = response.successBody,
                      receipt.blobID == attachmentID,
                      receipt.chunkIndex == index,
                      receipt.payload == encodedPayload else {
                    throw NoctCordAttachmentTransferError.malformedRelayResponse
                }
            }
        } catch {
            _ = try? await relayClient.send(.releaseMediaBlobV1(
                MediaBlobReleaseRequestV1(
                    blobID: attachmentID,
                    blobCapability: blobCapability
                )
            ))
            throw error
        }

        let keyID = Data(SHA256.hash(data: Self.domainData(
            "org.noctcord.attachment-key-id/v1",
            [keyData, Data(attachmentID.uuidString.utf8)]
        )))
        let manifest = NoctCordAttachmentManifestV1(
            blobID: Data(attachmentID.uuidString.utf8),
            blobCapability: blobCapability,
            mediaType: sanitized.mimeType,
            size: UInt64(sanitized.bytes.count),
            digest: plaintextDigest,
            expiresAt: expiresAt,
            encryption: NoctCordAttachmentEncryptionMetadataV1(
                keyID: keyID,
                contentKey: keyData,
                nonce: objectNonce,
                chunkSize: UInt32(Self.chunkSize)
            )
        )
        guard manifest.isStructurallyValid else {
            throw NoctCordAttachmentTransferError.invalidManifest
        }
        return NoctCordUploadedAttachment(
            id: attachmentID,
            manifest: manifest,
            kind: sanitized.kind,
            pixelWidth: sanitized.pixelWidth,
            pixelHeight: sanitized.pixelHeight,
            durationMilliseconds: sanitized.durationMilliseconds
        )
    }

    public func download(
        manifest: NoctCordAttachmentManifestV1,
        spaceID: UUID,
        channelID: UUID,
        now: Date = Date()
    ) async throws -> NoctCordDownloadedAttachment {
        guard manifest.isStructurallyValid,
              manifest.size <= UInt64(NoctCordAttachmentSanitizer.maximumBytes),
              let identifier = String(data: manifest.blobID, encoding: .utf8),
              let attachmentID = UUID(uuidString: identifier),
              manifest.encryption.chunkSize == UInt32(Self.chunkSize) else {
            throw NoctCordAttachmentTransferError.invalidManifest
        }
        guard now <= manifest.expiresAt else {
            throw NoctCordAttachmentTransferError.expired
        }
        let plaintextSize = Int(manifest.size)
        let chunkCount = (plaintextSize / Self.chunkSize)
            + (plaintextSize.isMultiple(of: Self.chunkSize) ? 0 : 1)
        guard (1...AttachmentDescriptor.maximumTransportChunks).contains(chunkCount) else {
            throw NoctCordAttachmentTransferError.invalidManifest
        }

        let key = SymmetricKey(data: manifest.encryption.contentKey)
        var reconstructed = Data()
        reconstructed.reserveCapacity(plaintextSize)
        for index in 0..<chunkCount {
            let response = try await relayClient.send(.fetchMediaBlobV1(
                MediaBlobFetchRequestV1(
                    blobID: attachmentID,
                    blobCapability: manifest.blobCapability,
                    chunkIndex: index
                )
            ))
            guard response.error == nil else {
                throw NoctCordAttachmentTransferError.relayRejected
            }
            guard case .mediaBlobChunk(let chunk)? = response.successBody,
                  chunk.blobID == attachmentID,
                  chunk.chunkIndex == index else {
                throw NoctCordAttachmentTransferError.malformedRelayResponse
            }
            let encryptedPayload: EncryptedPayload
            do {
                encryptedPayload = try Self.decode(chunk.payload)
            } catch {
                throw NoctCordAttachmentTransferError.malformedRelayResponse
            }
            let aad = Self.authenticatedData(
                spaceID: spaceID,
                channelID: channelID,
                attachmentID: attachmentID,
                chunkIndex: index,
                plaintextSize: plaintextSize,
                expiresAt: manifest.expiresAt,
                objectNonce: manifest.encryption.nonce
            )
            do {
                reconstructed.append(try CryptoBox.decrypt(
                    encryptedPayload,
                    key: key,
                    authenticatedData: aad
                ))
            } catch {
                throw NoctCordAttachmentTransferError.authenticationFailed
            }
        }
        guard reconstructed.count == plaintextSize else {
            throw NoctCordAttachmentTransferError.malformedRelayResponse
        }
        guard Data(SHA256.hash(data: reconstructed)) == manifest.digest else {
            throw NoctCordAttachmentTransferError.digestMismatch
        }
        return NoctCordDownloadedAttachment(
            id: attachmentID,
            bytes: reconstructed,
            mediaType: manifest.mediaType
        )
    }

    public func release(manifest: NoctCordAttachmentManifestV1) async throws {
        guard manifest.isStructurallyValid,
              let identifier = String(data: manifest.blobID, encoding: .utf8),
              let attachmentID = UUID(uuidString: identifier) else {
            throw NoctCordAttachmentTransferError.invalidManifest
        }
        let response = try await relayClient.send(.releaseMediaBlobV1(
            MediaBlobReleaseRequestV1(
                blobID: attachmentID,
                blobCapability: manifest.blobCapability
            )
        ))
        guard response.error == nil,
              response.successBody == .empty else {
            throw NoctCordAttachmentTransferError.relayRejected
        }
    }

    /// Compact fixed-field representation used only inside the opaque relay
    /// blob. It avoids filenames, MIME metadata, and JSON field names.
    private static func encode(_ payload: EncryptedPayload) -> Data {
        payload.nonce + payload.tag + payload.ciphertext
    }

    private static func decode(_ data: Data) throws -> EncryptedPayload {
        let header = EncryptedPayload.nonceByteCount + EncryptedPayload.tagByteCount
        guard data.count > header else {
            throw NoctCordAttachmentTransferError.malformedRelayResponse
        }
        let nonceEnd = EncryptedPayload.nonceByteCount
        let tagEnd = nonceEnd + EncryptedPayload.tagByteCount
        let payload = EncryptedPayload(
            nonce: data.subdata(in: 0..<nonceEnd),
            ciphertext: data.subdata(in: tagEnd..<data.count),
            tag: data.subdata(in: nonceEnd..<tagEnd)
        )
        guard payload.isStructurallyValid else {
            throw NoctCordAttachmentTransferError.malformedRelayResponse
        }
        return payload
    }

    private static func authenticatedData(
        spaceID: UUID,
        channelID: UUID,
        attachmentID: UUID,
        chunkIndex: Int,
        plaintextSize: Int,
        expiresAt: Date,
        objectNonce: Data
    ) -> Data {
        var index = UInt64(chunkIndex).bigEndian
        var size = UInt64(plaintextSize).bigEndian
        var expiry = UInt64(expiresAt.timeIntervalSince1970.rounded(.down)).bigEndian
        return domainData(
            "org.noctcord.attachment-chunk-aad/v1",
            [
                Data(spaceID.uuidString.utf8),
                Data(channelID.uuidString.utf8),
                Data(attachmentID.uuidString.utf8),
                Data(bytes: &index, count: MemoryLayout<UInt64>.size),
                Data(bytes: &size, count: MemoryLayout<UInt64>.size),
                Data(bytes: &expiry, count: MemoryLayout<UInt64>.size),
                objectNonce,
            ]
        )
    }

    private static func idempotencyKey(
        spaceID: UUID,
        channelID: UUID,
        attachmentID: UUID,
        chunkIndex: Int,
        payload: EncryptedPayload
    ) -> Data {
        var index = UInt64(chunkIndex).bigEndian
        return Data(SHA256.hash(data: domainData(
            "org.noctcord.attachment-upload-idempotency/v1",
            [
                Data(spaceID.uuidString.utf8),
                Data(channelID.uuidString.utf8),
                Data(attachmentID.uuidString.utf8),
                Data(bytes: &index, count: MemoryLayout<UInt64>.size),
                payload.nonce,
                payload.ciphertext,
                payload.tag,
            ]
        )))
    }

    private static func domainData(_ domain: String, _ components: [Data]) -> Data {
        var result = Data(domain.utf8)
        result.append(0)
        for component in components {
            var length = UInt64(component.count).bigEndian
            result.append(Data(bytes: &length, count: MemoryLayout<UInt64>.size))
            result.append(component)
        }
        return result
    }
}

private extension Data {
    func noctCordChunks(of maximumSize: Int) -> [Data] {
        guard maximumSize > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumSize).map { offset in
            let upper = Swift.min(offset + maximumSize, count)
            return subdata(in: offset..<upper)
        }
    }
}
