#!/usr/bin/env swift
import AppKit
import Foundation

guard (2...3).contains(CommandLine.arguments.count) else {
    FileHandle.standardError.write(
        Data("usage: render-app-icon.swift <output.iconset> [output.icns]\n".utf8)
    )
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1_024),
]

for variant in variants {
    let representation = try renderIcon(pixels: variant.pixels)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw IconError.encodingFailed
    }
    try data.write(to: outputDirectory.appendingPathComponent(variant.name), options: .atomic)
}

if CommandLine.arguments.count == 3 {
    try writeICNS(
        iconset: outputDirectory,
        output: URL(fileURLWithPath: CommandLine.arguments[2])
    )
}

private enum IconError: Error {
    case contextCreationFailed
    case encodingFailed
    case iconContainerTooLarge
}

private func writeICNS(iconset: URL, output: URL) throws {
    let entries: [(type: String, file: String)] = [
        ("icp4", "icon_16x16.png"),
        ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"),
        ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"),
    ]
    let payloads = try entries.map { entry in
        (entry.type, try Data(contentsOf: iconset.appendingPathComponent(entry.file)))
    }
    let byteCount = payloads.reduce(8) { $0 + 8 + $1.1.count }
    guard byteCount <= Int(UInt32.max) else { throw IconError.iconContainerTooLarge }

    var container = Data("icns".utf8)
    appendBigEndian(UInt32(byteCount), to: &container)
    for (type, payload) in payloads {
        container.append(Data(type.utf8))
        appendBigEndian(UInt32(payload.count + 8), to: &container)
        container.append(payload)
    }
    try container.write(to: output, options: .atomic)
}

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

private func renderIcon(pixels: Int) throws -> NSBitmapImageRep {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
        throw IconError.contextCreationFailed
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    context.imageInterpolation = .high

    let side = CGFloat(pixels)
    let canvas = NSRect(x: 0, y: 0, width: side, height: side)
    NSColor.clear.setFill()
    NSBezierPath(rect: canvas).fill()

    let inset = side * 0.052
    let tileRect = canvas.insetBy(dx: inset, dy: inset)
    let tile = NSBezierPath(
        roundedRect: tileRect,
        xRadius: side * 0.245,
        yRadius: side * 0.245
    )
    tile.addClip()

    let plumBlack = NSColor(srgbRed: 27 / 255, green: 18 / 255, blue: 23 / 255, alpha: 1)
    let deepWine = NSColor(srgbRed: 146 / 255, green: 45 / 255, blue: 53 / 255, alpha: 1)
    let mutedCoral = NSColor(srgbRed: 201 / 255, green: 106 / 255, blue: 97 / 255, alpha: 1)
    NSGradient(colors: [plumBlack, deepWine, mutedCoral])?.draw(in: tile, angle: -38)

    let sheen = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.16),
        NSColor.white.withAlphaComponent(0),
    ])
    sheen?.draw(in: tileRect, relativeCenterPosition: NSPoint(x: -0.55, y: 0.55))

    let center = NSPoint(x: side / 2, y: side / 2)
    var rotation = AffineTransform(translationByX: center.x, byY: center.y)
    rotation.rotate(byDegrees: -18)
    rotation.translate(x: -center.x, y: -center.y)

    let warmIvory = NSColor(srgbRed: 250 / 255, green: 243 / 255, blue: 234 / 255, alpha: 1)
    let paleSand = NSColor(srgbRed: 235 / 255, green: 199 / 255, blue: 175 / 255, alpha: 0.95)

    for index in 0..<3 {
        let width = side * 0.48
        let height = side * 0.19
        let xOffset = CGFloat(index - 1) * side * 0.115
        let linkRect = NSRect(
            x: center.x - width / 2 + xOffset,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        let link = NSBezierPath(
            roundedRect: linkRect,
            xRadius: side * 0.095,
            yRadius: side * 0.095
        )
        link.transform(using: rotation)
        (index == 1 ? warmIvory : paleSand).setStroke()
        link.lineWidth = max(1, side * 0.068)
        link.lineCapStyle = .round
        link.lineJoinStyle = .round
        link.stroke()
    }

    let innerBorder = NSBezierPath(
        roundedRect: tileRect,
        xRadius: side * 0.245,
        yRadius: side * 0.245
    )
    warmIvory.withAlphaComponent(0.12).setStroke()
    innerBorder.lineWidth = max(1, side * 0.009)
    innerBorder.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return representation
}
