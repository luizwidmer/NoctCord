import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum NoctCordAttachmentKind: String, Codable, Sendable {
    case image
    case video
    case audio
    case document
}

public struct NoctCordSanitizedAttachment: Sendable {
    public let bytes: Data
    public let mimeType: String
    public let kind: NoctCordAttachmentKind
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let durationMilliseconds: UInt64?

    public init(
        bytes: Data,
        mimeType: String,
        kind: NoctCordAttachmentKind,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        durationMilliseconds: UInt64? = nil
    ) {
        self.bytes = bytes
        self.mimeType = mimeType
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum NoctCordAttachmentSanitizerError: Error, Equatable, LocalizedError {
    case inaccessible
    case unsupportedType
    case malformed
    case unsafeDimensions
    case tooLarge
    case tooLong
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .inaccessible: "The selected file could not be read."
        case .unsupportedType: "This file type is not supported for channel uploads."
        case .malformed: "The file is malformed or does not match its declared media type."
        case .unsafeDimensions: "The media dimensions exceed the safe processing limit."
        case .tooLarge: "The sanitized attachment exceeds the 8 MB encrypted upload limit."
        case .tooLong: "Audio and video uploads are limited to 15 minutes."
        case .exportFailed: "The operating system could not produce a sanitized media copy."
        }
    }
}

/// Sanitizes bytes before they are encrypted or handed to a relay. The result
/// never contains the source filename. Image metadata is discarded by a fresh
/// pixel re-encode; audio/video metadata is discarded by a fresh AV export;
/// PDFs are flattened into a new document; text is normalized UTF-8.
public enum NoctCordAttachmentSanitizer {
    public static let maximumBytes = 8 * 1_024 * 1_024
    public static let maximumImageDimension = 4_096
    public static let maximumSourceImagePixels = 64 * 1_024 * 1_024
    public static let maximumSourceAVBytes = 256 * 1_024 * 1_024
    public static let maximumDuration: TimeInterval = 15 * 60
    public static let maximumPDFPages = 200

    public static func sanitize(url: URL) async throws -> NoctCordSanitizedAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            try NoctCordSecureFileIO.validateBoundedRegularFile(
                at: url,
                maximumBytes: maximumSourceAVBytes
            )
        } catch NoctCordSecureFileError.tooLarge {
            throw NoctCordAttachmentSanitizerError.tooLarge
        } catch {
            throw NoctCordAttachmentSanitizerError.inaccessible
        }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            throw NoctCordAttachmentSanitizerError.unsupportedType
        }
        if type.conforms(to: .image) {
            return try sanitizeImage(data: boundedData(at: url))
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return try await sanitizeStagedAVAsset(at: url, kind: .video)
        }
        if type.conforms(to: .audio) {
            return try await sanitizeStagedAVAsset(at: url, kind: .audio)
        }
        if type.conforms(to: .pdf) {
            return try sanitizePDF(data: boundedData(at: url))
        }
        if type.conforms(to: .plainText) || type.conforms(to: .text) || type == .json {
            return try sanitizeText(data: boundedData(at: url))
        }
        throw NoctCordAttachmentSanitizerError.unsupportedType
    }

    public static func sanitizeImage(data: Data) throws -> NoctCordSanitizedAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              sourceWidth > 0,
              sourceHeight > 0,
              sourceWidth <= 32_768,
              sourceHeight <= 32_768,
              sourceWidth.multipliedReportingOverflow(by: sourceHeight).overflow == false,
              sourceWidth * sourceHeight <= maximumSourceImagePixels else {
            throw NoctCordAttachmentSanitizerError.unsafeDimensions
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumImageDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NoctCordAttachmentSanitizerError.malformed
        }
        let hasAlpha = image.alphaInfo == .first
            || image.alphaInfo == .last
            || image.alphaInfo == .premultipliedFirst
            || image.alphaInfo == .premultipliedLast
        let outputType = hasAlpha ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            outputType.identifier as CFString,
            1,
            nil
        ) else {
            throw NoctCordAttachmentSanitizerError.exportFailed
        }
        let encodingProperties: [CFString: Any] = hasAlpha
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(destination, image, encodingProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NoctCordAttachmentSanitizerError.exportFailed
        }
        let bytes = output as Data
        try requireBoundedOutput(bytes)
        return NoctCordSanitizedAttachment(
            bytes: bytes,
            mimeType: hasAlpha ? "image/png" : "image/jpeg",
            kind: .image,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    public static func sanitizeText(data: Data) throws -> NoctCordSanitizedAttachment {
        guard data.count <= maximumBytes else {
            throw NoctCordAttachmentSanitizerError.tooLarge
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw NoctCordAttachmentSanitizerError.malformed
        }
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
        let filtered = String(normalized.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })
        guard let bytes = filtered.data(using: .utf8) else {
            throw NoctCordAttachmentSanitizerError.malformed
        }
        try requireBoundedOutput(bytes)
        return NoctCordSanitizedAttachment(
            bytes: bytes,
            mimeType: "text/plain",
            kind: .document
        )
    }

    public static func sanitizePDF(data: Data) throws -> NoctCordSanitizedAttachment {
        guard data.count <= maximumBytes else {
            throw NoctCordAttachmentSanitizerError.tooLarge
        }
        guard let document = PDFDocument(data: data),
              document.pageCount > 0,
              document.pageCount <= maximumPDFPages else {
            throw NoctCordAttachmentSanitizerError.malformed
        }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw NoctCordAttachmentSanitizerError.exportFailed
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                throw NoctCordAttachmentSanitizerError.malformed
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width.isFinite,
                  bounds.height.isFinite,
                  bounds.width > 0,
                  bounds.height > 0,
                  bounds.width <= 20_000,
                  bounds.height <= 20_000 else {
                throw NoctCordAttachmentSanitizerError.unsafeDimensions
            }
            context.beginPDFPage([kCGPDFContextMediaBox as String: bounds] as CFDictionary)
            context.saveGState()
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        let bytes = output as Data
        try requireBoundedOutput(bytes)
        return NoctCordSanitizedAttachment(
            bytes: bytes,
            mimeType: "application/pdf",
            kind: .document
        )
    }

    private static func sanitizeAVAsset(
        at sourceURL: URL,
        kind: NoctCordAttachmentKind
    ) async throws -> NoctCordSanitizedAttachment {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw NoctCordAttachmentSanitizerError.malformed
        }
        guard duration <= maximumDuration else {
            throw NoctCordAttachmentSanitizerError.tooLong
        }
        let preset = kind == .video
            ? AVAssetExportPreset1280x720
            : AVAssetExportPresetAppleM4A
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NoctCordAttachmentSanitizerError.exportFailed
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctcord-media-\(UUID().uuidString)")
            .appendingPathExtension(kind == .video ? "mp4" : "m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        exporter.outputURL = outputURL
        exporter.outputFileType = kind == .video ? .mp4 : .m4a
        exporter.shouldOptimizeForNetworkUse = true
        exporter.metadata = []
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else {
            throw NoctCordAttachmentSanitizerError.exportFailed
        }
        let bytes = try boundedData(at: outputURL)
        try requireBoundedOutput(bytes)
        var width: Int?
        var height: Int?
        if kind == .video,
           let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = size.applying(transform)
            width = Int(abs(transformed.width).rounded())
            height = Int(abs(transformed.height).rounded())
        }
        return NoctCordSanitizedAttachment(
            bytes: bytes,
            mimeType: kind == .video ? "video/mp4" : "audio/mp4",
            kind: kind,
            pixelWidth: width,
            pixelHeight: height,
            durationMilliseconds: UInt64((duration * 1_000).rounded())
        )
    }

    private static func sanitizeStagedAVAsset(
        at sourceURL: URL,
        kind: NoctCordAttachmentKind
    ) async throws -> NoctCordSanitizedAttachment {
        let extensionComponent = sourceURL.pathExtension.lowercased()
        var stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctcord-source-\(UUID().uuidString)")
        if !extensionComponent.isEmpty {
            stagedURL.appendPathExtension(extensionComponent)
        }
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        do {
            try NoctCordSecureFileIO.copyBoundedRegularFile(
                at: sourceURL,
                to: stagedURL,
                maximumBytes: maximumSourceAVBytes
            )
        } catch NoctCordSecureFileError.tooLarge {
            throw NoctCordAttachmentSanitizerError.tooLarge
        } catch {
            throw NoctCordAttachmentSanitizerError.inaccessible
        }
        return try await sanitizeAVAsset(at: stagedURL, kind: kind)
    }

    private static func boundedData(at url: URL) throws -> Data {
        do {
            return try NoctCordSecureFileIO.readBoundedRegularFile(
                at: url,
                maximumBytes: maximumBytes * 4
            )
        } catch NoctCordSecureFileError.tooLarge {
            throw NoctCordAttachmentSanitizerError.tooLarge
        } catch {
            throw NoctCordAttachmentSanitizerError.inaccessible
        }
    }

    private static func requireBoundedOutput(_ data: Data) throws {
        guard !data.isEmpty else { throw NoctCordAttachmentSanitizerError.malformed }
        guard data.count <= maximumBytes else { throw NoctCordAttachmentSanitizerError.tooLarge }
    }
}
