#!/usr/bin/env swift
//
// Turns Resources/AppIcon.png into the AppIcon.icns that ships inside the app.
//
// Doing this at build time rather than committing the .icns keeps one source
// image in the repository instead of ten rendered copies of it.
//
//   swift scripts/make-icon.swift <output.icns> [source.png]

import AppKit
import Foundation

let arguments = CommandLine.arguments
let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "AppIcon.icns")
let source = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "Resources/AppIcon.png")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

guard let image = NSImage(contentsOf: source),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff)
else { fail("could not read \(source.path)") }

/// Trims the flat border around the artwork.
///
/// The source is a square picture of a rounded square, and the few pixels of
/// background around it would otherwise show up as a pale ring once the icon is
/// masked to the shape macOS expects.
func contentBounds(of bitmap: NSBitmapImageRep) -> NSRect {
    let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
    guard let background = bitmap.colorAt(x: 0, y: 0) else {
        return NSRect(x: 0, y: 0, width: width, height: height)
    }

    func differs(_ x: Int, _ y: Int) -> Bool {
        guard let pixel = bitmap.colorAt(x: x, y: y) else { return false }
        let distance = abs(pixel.redComponent - background.redComponent)
            + abs(pixel.greenComponent - background.greenComponent)
            + abs(pixel.blueComponent - background.blueComponent)
        return distance > 0.012 || pixel.alphaComponent < 0.99
    }

    var left = 0, right = width - 1, top = 0, bottom = height - 1
    while left < width - 1, !differs(left, height / 2) { left += 1 }
    while right > left, !differs(right, height / 2) { right -= 1 }
    while top < height - 1, !differs(width / 2, top) { top += 1 }
    while bottom > top, !differs(width / 2, bottom) { bottom -= 1 }

    return NSRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
}

let artwork = contentBounds(of: bitmap)

/// One icon at one size.
///
/// macOS icons are a rounded square inside a margin rather than a full-bleed
/// square, so the artwork is masked to that shape and drawn very slightly larger
/// than the mask — enough that its own rounded corners fall outside and cannot
/// leave pale wedges behind.
func render(pixels: Int) -> Data? {
    guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

    let size = CGFloat(pixels)
    let margin = size * 0.085
    let plate = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let corner = plate.width * 0.2237

    NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner).addClip()

    let overscan = plate.width * 0.015
    image.draw(in: plate.insetBy(dx: -overscan, dy: -overscan),
               from: artwork,
               operation: .sourceOver,
               fraction: 1,
               respectFlipped: true,
               hints: [.interpolation: NSImageInterpolation.high.rawValue])

    NSGraphicsContext.restoreGraphicsState()
    return canvas.representation(using: .png, properties: [:])
}

let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("switchboard-icon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        guard let data = render(pixels: pixels) else { fail("could not render \(pixels)px") }
        let suffix = scale == 1 ? "" : "@2x"
        try data.write(to: workspace.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", workspace.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: workspace)

guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(output.path)")
