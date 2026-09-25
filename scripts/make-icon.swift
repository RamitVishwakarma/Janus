#!/usr/bin/env swift
//
// Draws the app icon and writes AppIcon.icns.
//
// Generated rather than committed so the repository stays text, and so the icon
// can be changed by editing colours here instead of opening a design tool.
//
//   swift scripts/make-icon.swift <output.icns>

import AppKit
import Foundation

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "AppIcon.icns")

/// macOS icons sit inside a rounded square with a margin around it, rather than
/// filling the canvas edge to edge.
func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let margin = size * 0.085
    let plate = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let corner = plate.width * 0.2237

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.35, green: 0.47, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.25, blue: 0.85, alpha: 1)
    ])
    gradient?.draw(in: NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner),
                   angle: -90)

    // Two opposed arrows: the switch, drawn rather than set in a font so it
    // renders identically on every machine that builds this.
    let inset = plate.width * 0.26
    let body = plate.insetBy(dx: inset, dy: inset * 1.22)
    let stroke = max(1, plate.width * 0.062)
    let head = stroke * 1.65
    let gap = body.height * 0.5

    NSColor.white.setStroke()
    NSColor.white.setFill()

    for (index, pointingRight) in [true, false].enumerated() {
        let y = body.midY + (index == 0 ? gap / 2 : -gap / 2)
        let tipX = pointingRight ? body.maxX : body.minX
        let tailX = pointingRight ? body.minX : body.maxX
        let direction: CGFloat = pointingRight ? -1 : 1

        let shaft = NSBezierPath()
        shaft.move(to: NSPoint(x: tailX, y: y))
        shaft.line(to: NSPoint(x: tipX + direction * head * 0.5, y: y))
        shaft.lineWidth = stroke
        shaft.lineCapStyle = .round
        shaft.stroke()

        let arrowhead = NSBezierPath()
        arrowhead.move(to: NSPoint(x: tipX, y: y))
        arrowhead.line(to: NSPoint(x: tipX + direction * head, y: y + head * 0.82))
        arrowhead.line(to: NSPoint(x: tipX + direction * head, y: y - head * 0.82))
        arrowhead.close()
        arrowhead.fill()
    }

    return image
}

func png(_ image: NSImage, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("janus-icon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        guard let data = png(draw(size: CGFloat(pixels)), pixels: pixels) else {
            FileHandle.standardError.write(Data("could not render \(pixels)px\n".utf8))
            exit(1)
        }
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
