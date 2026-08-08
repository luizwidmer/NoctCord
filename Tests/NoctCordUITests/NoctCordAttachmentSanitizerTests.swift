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
