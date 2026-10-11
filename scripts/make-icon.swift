#!/usr/bin/env swift
// SPDX-License-Identifier: AGPL-3.0-only
//
// Draws the khensu.nu app icon (PLAN.md, App design): a thin white ring with a
// second, unfilled arc just inside its left half, meeting the ring at top and
// bottom centre, on a true-black tile with a faint dot network.
//
// Usage: swift scripts/make-icon.swift <output.png> [size]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: make-icon.swift <output.png> [size]")
    exit(1)
}
let size = args.count > 2 ? Int(args[2])! : 1024
let s = CGFloat(size)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Tile: true black with a graphite glow behind the mark.
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
let glow = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1),
    CGColor(red: 0, green: 0, blue: 0, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                       endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s * 0.62, options: [])

// Dot network: a deterministic scatter, near pairs joined by hairlines.
var rng: UInt64 = 0x6b68_656e_7375
func rand() -> CGFloat {
    rng = rng &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(rng >> 33) / CGFloat(1 << 31)
}
let dots = (0..<46).map { _ in CGPoint(x: rand() * s, y: rand() * s) }
ctx.setLineWidth(max(1, s / 1024))
for (i, a) in dots.enumerated() {
    for b in dots[(i + 1)...] {
        let d = hypot(a.x - b.x, a.y - b.y)
        if d < s * 0.2 {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10 * (1 - d / (s * 0.2))))
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
        }
    }
}
for p in dots {
    let r = s * (0.003 + 0.004 * rand())
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.25 + 0.35 * rand()))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
}

// The mark.
let c = CGPoint(x: s / 2, y: s / 2)
let r = s * 0.30
let line = s * 0.02
ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineWidth(line)
ctx.setLineCap(.round)
ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
ctx.strokePath()

// Inner arc: a circle slightly larger than the ring, centred to the right so it
// meets the ring exactly at top and bottom centre and bows into the left half.
let r2 = r * 1.16
let dx = sqrt(r2 * r2 - r * r)
let c2 = CGPoint(x: c.x + dx, y: c.y)
let half = asin(r / r2)
ctx.addArc(center: c2, radius: r2, startAngle: .pi - half, endAngle: .pi + half, clockwise: false)
ctx.strokePath()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: args[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("wrote \(url.path) (\(size)×\(size))")
