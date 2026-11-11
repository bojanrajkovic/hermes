#!/usr/bin/env swift
//
// make-icon.swift — render the app icon at every macOS size.
//
// Draws a pull request mark (two branch nodes joined by a line, and a third
// node an arrow merges into) with a gold wing on the merging node: Hermes, the
// messenger, carrying a change to its base. Pure AppKit drawing, no assets.
// The Makefile runs `iconutil -c icns build/AppIcon.iconset` on the PNGs.

import AppKit

let iconsetDir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// (filename, pixel dimension) — the set iconutil expects.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func draw(into ctx: CGContext, size s: CGFloat) {
    // Background tile: a rounded rect with a night-sky gradient.
    let inset = s * 0.06
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let corner = s * 0.22
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.27, green: 0.30, blue: 0.62, alpha: 1),
            CGColor(red: 0.09, green: 0.10, blue: 0.27, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    drawPullRequest(into: ctx, tile: tile)
}

/// Points are given in a unit square (origin bottom left) and mapped into the tile.
func drawPullRequest(into ctx: CGContext, tile: CGRect) {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + x * tile.width, y: tile.minY + y * tile.height)
    }
    let unit = tile.width
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 0.97)
    let gold = CGColor(red: 1.0, green: 0.78, blue: 0.28, alpha: 1)
    let stroke = unit * 0.062
    let nodeRadius = unit * 0.082

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // The wing: three pointed feathers sweeping back from the merging node,
    // the longest on top. Each is a blade between an outer and an inner curve.
    let root = point(0.58, 0.31)
    let feathers: [(tip: CGPoint, outer: CGPoint, inner: CGPoint)] = [
        (point(0.90, 0.78), point(0.58, 0.66), point(0.80, 0.52)),
        (point(0.93, 0.58), point(0.70, 0.56), point(0.84, 0.40)),
        (point(0.88, 0.40), point(0.76, 0.44), point(0.78, 0.30)),
    ]
    ctx.setFillColor(gold)
    for feather in feathers {
        ctx.move(to: root)
        ctx.addQuadCurve(to: feather.tip, control: feather.outer)
        ctx.addQuadCurve(to: root, control: feather.inner)
        ctx.fillPath()
    }

    // The base branch: two nodes joined by a straight line.
    ctx.setStrokeColor(white)
    ctx.setLineWidth(stroke)
    ctx.move(to: point(0.24, 0.70))
    ctx.addLine(to: point(0.24, 0.30))
    ctx.strokePath()

    // The head branch: from the upper left, curving down into the merging node.
    ctx.move(to: point(0.38, 0.72))
    ctx.addCurve(to: point(0.58, 0.42), control1: point(0.52, 0.72), control2: point(0.58, 0.62))
    ctx.strokePath()
    // Its arrowhead, pointing back at where the change came from.
    ctx.move(to: point(0.46, 0.80))
    ctx.addLine(to: point(0.37, 0.72))
    ctx.addLine(to: point(0.46, 0.64))
    ctx.strokePath()

    // Nodes: rings with the tile showing through, drawn last so lines end under them.
    for center in [point(0.24, 0.74), point(0.24, 0.27), point(0.58, 0.30)] {
        let ring = CGRect(x: center.x - nodeRadius, y: center.y - nodeRadius, width: 2 * nodeRadius, height: 2 * nodeRadius)
        ctx.setFillColor(CGColor(red: 0.13, green: 0.15, blue: 0.36, alpha: 1))
        ctx.fillEllipse(in: ring)
        ctx.setStrokeColor(white)
        ctx.setLineWidth(stroke)
        ctx.strokeEllipse(in: ring)
    }
}

for (name, px) in variants {
    let dim = CGFloat(px)
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { continue }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(into: ctx, size: dim)
    guard let image = ctx.makeImage() else { continue }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(name)"))
}

print("✓ wrote \(variants.count) icons to \(iconsetDir)")
