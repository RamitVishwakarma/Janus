#!/usr/bin/env swift
//
// Renders the 1280x640 card GitHub shows when the repository is linked from
// anywhere else: X, Reddit, Slack, Product Hunt. Without one, every share of
// the project is a grey box with a filename in it.
//
// Upload the result under Settings -> General -> Social preview.
//
//   swift scripts/make-social.swift [output.png] [icon.png]

import AppKit
import Foundation

let arguments = CommandLine.arguments
let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "demo/social-preview.png")
let iconPath = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "Resources/AppIcon.png")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-social: \(message)\n".utf8))
    exit(1)
}

let width: CGFloat = 1280
let height: CGFloat = 640

guard let canvas = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width), pixelsHigh: Int(height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fail("could not allocate the canvas") }

guard let context = NSGraphicsContext(bitmapImageRep: canvas) else {
    fail("could not draw into the canvas")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

/// The canvas has its origin at the bottom left; every measurement below is
/// taken from the top, which is how the layout is easier to reason about.
func fromTop(_ y: CGFloat, _ boxHeight: CGFloat) -> CGFloat { height - y - boxHeight }

let background = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
let heading = NSColor(calibratedWhite: 0.97, alpha: 1)
let body = NSColor(calibratedWhite: 0.62, alpha: 1)
let faint = NSColor(calibratedWhite: 0.42, alpha: 1)

background.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

// A hairline across the top, the same one the app draws under its tab bar.
NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
NSBezierPath(rect: NSRect(x: 0, y: height - 3, width: width, height: 3)).fill()

let margin: CGFloat = 96
let iconSize: CGFloat = 168

if let icon = NSImage(contentsOf: iconPath) {
    let box = NSRect(x: margin, y: fromTop(112, iconSize), width: iconSize, height: iconSize)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: box, xRadius: 38, yRadius: 38).addClip()
    icon.draw(in: box)
    NSGraphicsContext.restoreGraphicsState()
}

let textLeft = margin + iconSize + 44

"Janus".draw(
    at: NSPoint(x: textLeft, y: fromTop(126, 96)),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 84, weight: .bold),
        .foregroundColor: heading,
    ]
)

let tagline = NSMutableParagraphStyle()
tagline.lineHeightMultiple = 1.18
"Switch Claude Code accounts from\nthe macOS menu bar."
    .draw(
        in: NSRect(x: textLeft, y: fromTop(232, 110), width: width - textLeft - margin, height: 110),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 38, weight: .regular),
            .foregroundColor: body,
            .paragraphStyle: tagline,
        ]
    )

// Two usage bars, the detail the app is actually built around: one account
// nearly spent, one with room left.
func bar(y: CGFloat, fraction: CGFloat, colour: NSColor, label: String) {
    let barWidth: CGFloat = 430
    let track = NSRect(x: margin, y: fromTop(y, 12), width: barWidth, height: 12)
    NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
    NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).fill()

    colour.setFill()
    let filled = NSRect(x: margin, y: track.origin.y, width: barWidth * fraction, height: 12)
    NSBezierPath(roundedRect: filled, xRadius: 6, yRadius: 6).fill()

    label.draw(
        at: NSPoint(x: margin + barWidth + 22, y: fromTop(y + 3, 26)),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: faint,
        ]
    )
}

// The line the whole project is positioned on, sitting with the thing that
// makes it true.
"Know which account has room left.".draw(
    at: NSPoint(x: margin, y: fromTop(372, 30)),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1),
    ]
)

bar(y: 434, fraction: 0.94, colour: NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.13, alpha: 1),
    label: "94% used")
bar(y: 482, fraction: 0.05, colour: NSColor(calibratedRed: 0.24, green: 0.80, blue: 0.35, alpha: 1),
    label: "5% used")

"MIT  ·  macOS 13+  ·  github.com/RamitVishwakarma/Janus".draw(
    at: NSPoint(x: margin, y: fromTop(552, 30)),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 25, weight: .regular),
        .foregroundColor: faint,
    ]
)

NSGraphicsContext.restoreGraphicsState()

guard let png = canvas.representation(using: .png, properties: [:]) else {
    fail("could not encode the card")
}
try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true
)
do { try png.write(to: output) } catch { fail("could not write \(output.path): \(error)") }

print("==> \(output.path)  \(Int(width))x\(Int(height))")
