#!/usr/bin/env swift
//
// Builds the demo frames from a real capture of the Janus window. Nothing is
// drawn that the app does not draw. The Switch control, the "In use" label,
// the selected marker and the subtitle line move between the two rows exactly
// as a switch moves them, and the status line the app itself wrote is revealed
// on the click. Addresses are blurred.

import AppKit
import CoreImage
import Foundation

let args = CommandLine.arguments
let basePath = args.count > 1 ? args[1] : "/tmp/janusfab/base.png"
let outDir = args.count > 2 ? args[2] : "/tmp/janusfab/frames"

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data("frames: \(m)\n".utf8)); exit(1)
}

guard let img = NSImage(contentsOfFile: basePath),
      let tiff = img.tiffRepresentation,
      let base = NSBitmapImageRep(data: tiff),
      let baseCG = base.cgImage else { fail("cannot read \(basePath)") }

let W = base.pixelsWide, H = base.pixelsHigh
let S: CGFloat = 2.0

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// A rectangle in window points, measured from the accessibility tree.
struct R {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    /// Top left origin, which CGImage crops in.
    var px: CGRect { CGRect(x: x * S, y: y * S, width: w * S, height: h * S) }
    /// Bottom left origin, which the drawing context uses.
    var dst: NSRect { NSRect(x: x * S, y: CGFloat(H) - (y + h) * S, width: w * S, height: h * S) }
    func grown(_ p: CGFloat) -> R { R(x: x - p, y: y - p, w: w + p * 2, h: h + p * 2) }
}

let switchSrc = R(x: 508, y: 147, w: 74, h: 33)
let switchDst = R(x: 511, y: 238, w: 68, h: 27)
let inUseSrc  = R(x: 542, y: 243, w: 36, h: 17)
let inUseDst  = R(x: 542, y: 155, w: 36, h: 17)
let radio1    = R(x: 66, y: 156, w: 16, h: 16)
let radio2    = R(x: 66, y: 244, w: 16, h: 16)
let sub1       = R(x: 92, y: 181, w: 380, h: 17)   // measured ... · Claude Code ...
let sub2       = R(x: 92, y: 269, w: 380, h: 17)   // current · Claude Code ...
let statusArea = R(x: 8, y: 486, w: 604, h: 54)

let rowEmails = [R(x: 93, y: 131, w: 134, h: 16), R(x: 93, y: 219, w: 193, h: 16)]
let statusEmails = [R(x: 91, y: 490, w: 170, h: 17), R(x: 46, y: 507, w: 104, h: 15)]

func crop(_ r: R) -> NSImage {
    guard let cg = baseCG.cropping(to: r.px) else { fail("crop \(r)") }
    return NSImage(cgImage: cg, size: NSSize(width: r.w * S, height: r.h * S))
}

let ci = CIContext()
/// Blurs a patch of the capture so an address is unreadable but the line still
/// looks like text sitting where text sat.
func blurPatch(_ r: R, radius: Double) -> (R, NSImage)? {
    let wide = r.grown(6)
    guard let piece = baseCG.cropping(to: wide.px) else { return nil }
    let input = CIImage(cgImage: piece)
    guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
    f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
    f.setValue(radius, forKey: kCIInputRadiusKey)
    guard let out = f.outputImage?.cropped(to: input.extent),
          let cg = ci.createCGImage(out, from: input.extent) else { return nil }
    return (wide, NSImage(cgImage: cg, size: NSSize(width: wide.w * S, height: wide.h * S)))
}

let switchChip = crop(switchSrc)
let inUseChip  = crop(inUseSrc)
let radio1Chip = crop(radio1)
let radio2Chip = crop(radio2)
let sub1Chip   = crop(sub1)
let sub2Chip   = crop(sub2)
let statusChip = crop(statusArea)
/// Panel colour beside each row's controls, so a cleared control leaves the
/// background it was sitting on.
func sample(_ xPoint: CGFloat, _ yPoint: CGFloat) -> NSColor {
    base.colorAt(x: Int(xPoint * S), y: Int(yPoint * S)) ?? NSColor.black
}
let blankOne = crop(R(x: 420, y: 147, w: 74, h: 33))
let blankTwo = crop(R(x: 420, y: 243, w: 36, h: 17))

let rowBlurs = rowEmails.compactMap { blurPatch($0, radius: 8) }
let statusBlurs = statusEmails.compactMap { blurPatch($0, radius: 7) }

/// The macOS arrow, drawn rather than captured so it stays crisp.
func drawCursor(at p: NSPoint) {
    let k = S * 0.62
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 17.5), (4.1, 13.6), (6.8, 19.6),
                                     (9.4, 18.4), (6.7, 12.6), (12.2, 12.2)]
    let path = NSBezierPath()
    path.move(to: p)
    for (dx, dy) in pts.dropFirst() { path.line(to: NSPoint(x: p.x + dx * k, y: p.y - dy * k)) }
    path.close()
    NSColor.white.setStroke()
    path.lineWidth = 2.4
    path.lineJoinStyle = .round
    path.stroke()
    NSColor.black.setFill()
    path.fill()
}

let total = 108
let glideStart = 10, glideEnd = 32
let pressFrame = 38
let startPoint = NSPoint(x: 300 * S, y: CGFloat(H) - 420 * S)
let targetPoint = NSPoint(x: 527 * S, y: CGFloat(H) - 170 * S)

func ease(_ t: CGFloat) -> CGFloat { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

for f in 0..<total {
    guard let canvas = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: canvas) else { fail("no canvas") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    base.draw(in: NSRect(x: 0, y: 0, width: W, height: H))

    let switched = f >= pressFrame

    if switched {
        // Clear where each control sat, using the panel colour beside it, then
        // put the two rows' controls back the other way round.
        blankOne.draw(in: switchSrc.dst)
        blankTwo.draw(in: inUseSrc.dst)

        switchChip.draw(in: switchDst.dst)
        inUseChip.draw(in: inUseDst.dst)
        radio2Chip.draw(in: radio1.dst)
        radio1Chip.draw(in: radio2.dst)
        sub2Chip.draw(in: sub1.dst)
        sub1Chip.draw(in: sub2.dst)
    } else {
        // The status line belongs to the switch, so hide it until the click.
        statusChip.draw(in: statusArea.dst)
        NSColor(calibratedRed: 0.106, green: 0.106, blue: 0.11, alpha: 1).setFill()
        NSBezierPath(rect: statusArea.dst).fill()
    }

    for (r, b) in rowBlurs { b.draw(in: r.dst) }
    if switched { for (r, b) in statusBlurs { b.draw(in: r.dst) } }

    var p = startPoint
    if f >= glideEnd {
        p = targetPoint
    } else if f > glideStart {
        let t = ease(CGFloat(f - glideStart) / CGFloat(glideEnd - glideStart))
        p = NSPoint(x: startPoint.x + (targetPoint.x - startPoint.x) * t,
                    y: startPoint.y + (targetPoint.y - startPoint.y) * t)
    }
    if f >= pressFrame - 3 && f < pressFrame {
        NSColor(calibratedWhite: 0, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: switchSrc.dst, xRadius: 6, yRadius: 6).fill()
    }
    drawCursor(at: p)

    NSGraphicsContext.restoreGraphicsState()
    guard let png = canvas.representation(using: .png, properties: [:]) else { fail("encode") }
    try? png.write(to: URL(fileURLWithPath: String(format: "%@/f%04d.png", outDir, f)))
}
print("==> \(total) frames in \(outDir)")
