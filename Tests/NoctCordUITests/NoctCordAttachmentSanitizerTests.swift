import CoreGraphics
import ImageIO
@testable import NoctCordUI
import UniformTypeIdentifiers
import XCTest

@MainActor
final class NoctCordAttachmentSanitizerTests: XCTestCase {
    func testTextIsNormalizedAndControlCharactersAreRemoved() throws {
        let input = Data("first\r\nsecond\rthird\u{0000}\tvalue".utf8)

        let result = try NoctCordAttachmentSanitizer.sanitizeText(data: input)

        XCTAssertEqual(result.kind, .document)
        XCTAssertEqual(result.mimeType, "text/plain")
        XCTAssertEqual(String(data: result.bytes, encoding: .utf8), "first\nsecond\nthird\tvalue")
    }

    func testImageIsReencodedWithoutSourceMetadata() throws {
        let input = try imageWithMetadata()

        let result = try NoctCordAttachmentSanitizer.sanitizeImage(data: input)

        XCTAssertEqual(result.kind, .image)
        XCTAssertEqual(result.mimeType, "image/jpeg")
        XCTAssertEqual(result.pixelWidth, 8)
        XCTAssertEqual(result.pixelHeight, 8)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.bytes as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
    }

    func testOversizedTextIsRejectedBeforeProcessing() {
        let bytes = Data(repeating: 0x61, count: NoctCordAttachmentSanitizer.maximumBytes + 1)

        XCTAssertThrowsError(try NoctCordAttachmentSanitizer.sanitizeText(data: bytes)) { error in
            XCTAssertEqual(error as? NoctCordAttachmentSanitizerError, .tooLarge)
        }
    }

    func testReceivedImageIsSanitizedBeforeEnteringPreviewCache() throws {
        let id = UUID()
        let incoming = NoctCordDownloadedAttachment(
            id: id, bytes: try imageWithMetadata(), mediaType: "image/jpeg"
        )
        let preview = try NoctCordAttachmentSanitizer.prepareReceivedPreview(incoming)
        XCTAssertEqual(preview.id, id)
        XCTAssertEqual(preview.mediaType, "image/jpeg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(preview.bytes as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 8)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
    }

    func testReceivedOversizedImageHeaderIsRejectedBeforePreviewDecode() throws {
        var bytes = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+yKxkAAAAASUVORK5CYII="
        ))
        // Patch only the bounded PNG header. Never allocate or decode the
        // claimed pixel buffer when testing a hostile image's dimensions.
        bytes.replaceSubrange(16..<20, with: [0, 0, 0x80, 1])
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        crc ^= 0xFFFF_FFFF
        bytes.replaceSubrange(29..<33, with: [
            UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16),
            UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc),
        ])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 32_769)
        let incoming = NoctCordDownloadedAttachment(id: UUID(), bytes: bytes, mediaType: "image/png")
        XCTAssertThrowsError(try NoctCordAttachmentSanitizer.prepareReceivedPreview(incoming)) {
            XCTAssertEqual($0 as? NoctCordAttachmentSanitizerError, .unsafeDimensions)
        }
    }

    func testVideoDimensionsRejectNonFiniteAndOutOfRangeMetadata() throws {
        XCTAssertEqual(
            try NoctCordAttachmentSanitizer.validatedVideoPixelDimension(-720.4),
            720
        )
        for value in [
            CGFloat.zero,
            CGFloat.nan,
            CGFloat.infinity,
            CGFloat(NoctCordAttachmentSanitizer.maximumImageDimension + 1),
        ] {
            XCTAssertThrowsError(
                try NoctCordAttachmentSanitizer.validatedVideoPixelDimension(value)
            ) { error in
                XCTAssertEqual(
                    error as? NoctCordAttachmentSanitizerError,
                    .unsafeDimensions
                )
            }
        }
    }

    func testSymlinkedInputIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-attachment-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let realURL = root.appendingPathComponent("real.txt")
        try Data("private".utf8).write(to: realURL)
        let linkedURL = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: realURL)

        do {
            _ = try await NoctCordAttachmentSanitizer.sanitize(url: linkedURL)
            XCTFail("Expected symlinked attachment to be rejected")
        } catch let error as NoctCordAttachmentSanitizerError {
            XCTAssertEqual(error, .inaccessible)
        }
    }

    private func imageWithMetadata() throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 8,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 8 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42.0],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private"],
        ]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
