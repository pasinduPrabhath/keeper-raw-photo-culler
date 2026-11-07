#!/usr/bin/env swift
// Generates Resources/AppIcon.icns from code, so the icon is reproducible and easy to tweak.
//   swift Scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824 pt squircle inside 1024 pt canvas.
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(squircle); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.10, green: 0.13, blue: 0.26, alpha: 1), CGColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.31, green: 0.65, blue: 1, alpha: 0.38), CGColor(red: 0.31, green: 0.65, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 460, options: [])

    // Aperture: ring + six blades.
    let center = CGPoint(x: 512, y: 540)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.94)); ctx.setLineWidth(46)
    ctx.strokeEllipse(in: CGRect(x: center.x - 250, y: center.y - 250, width: 500, height: 500))
    for i in 0 ..< 6 {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(i) * .pi / 3)
        let blade = CGMutablePath()
        blade.move(to: CGPoint(x: -34, y: 60)); blade.addLine(to: CGPoint(x: 205, y: 118)); blade.addLine(to: CGPoint(x: 205, y: 40)); blade.addLine(to: CGPoint(x: 40, y: -12)); blade.closeSubpath()
        ctx.addPath(blade)
        ctx.setFillColor(CGColor(red: 0.31, green: 0.65, blue: 1, alpha: 0.25 + CGFloat(i) * 0.1)); ctx.fillPath()
        ctx.addPath(blade); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55)); ctx.setLineWidth(6); ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // "Keeper" check badge.
    let badge = CGRect(x: 600, y: 160, width: 250, height: 250)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.5))
    ctx.setFillColor(CGColor(red: 0.24, green: 0.80, blue: 0.48, alpha: 1)); ctx.fillEllipse(in: badge)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setStrokeColor(CGColor(gray: 0.04, alpha: 1)); ctx.setLineWidth(34); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 668, y: 288)); ctx.addLine(to: CGPoint(x: 714, y: 238)); ctx.addLine(to: CGPoint(x: 790, y: 336)); ctx.strokePath()

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                                 ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in variants { try render(size: px).write(to: iconset.appendingPathComponent("icon_\(name).png")) }
try render(size: 1024).write(to: root.appendingPathComponent("docs/icon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns and docs/icon.png")
