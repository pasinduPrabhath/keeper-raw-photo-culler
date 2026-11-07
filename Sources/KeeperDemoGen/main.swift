import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import KeeperCore
import UniformTypeIdentifiers

// KeeperDemoGen: writes a fake wildlife shoot (synthetic ARW files) so you can try Keeper without a camera.
//
//   swift run KeeperDemoGen ./DemoShoot            # RAW only
//   swift run KeeperDemoGen ./DemoShoot --pairs    # also write a camera-style JPEG next to each RAW

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

let args = CommandLine.arguments.dropFirst()
guard let outPath = args.first(where: { !$0.hasPrefix("--") }) else {
    print("usage: KeeperDemoGen <output-folder> [--pairs]")
    exit(1)
}
let pairs = args.contains("--pairs")
let outURL = URL(fileURLWithPath: outPath, isDirectory: true)
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

var rng = SplitMix(state: 20_261_107)
let ci = CIContext()
let W = 1620, H = 1080

struct Palette { let skyTop: CGColor, skyBottom: CGColor, sun: CGColor, hills: CGColor, bird: CGColor, belly: CGColor, accent: CGColor }
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
let palettes: [Palette] = [
    Palette(skyTop: rgb(0.16, 0.22, 0.42), skyBottom: rgb(0.98, 0.64, 0.34), sun: rgb(1, 0.86, 0.55), hills: rgb(0.10, 0.12, 0.18), bird: rgb(0.10, 0.34, 0.62), belly: rgb(0.95, 0.52, 0.18), accent: rgb(0.95, 0.9, 0.8)),
    Palette(skyTop: rgb(0.32, 0.55, 0.78), skyBottom: rgb(0.86, 0.92, 0.94), sun: rgb(1, 1, 0.92), hills: rgb(0.16, 0.30, 0.22), bird: rgb(0.34, 0.22, 0.14), belly: rgb(0.86, 0.80, 0.68), accent: rgb(1, 1, 1)),
    Palette(skyTop: rgb(0.30, 0.16, 0.34), skyBottom: rgb(0.99, 0.50, 0.40), sun: rgb(1, 0.78, 0.5), hills: rgb(0.08, 0.06, 0.12), bird: rgb(0.12, 0.12, 0.14), belly: rgb(0.80, 0.78, 0.74), accent: rgb(0.95, 0.35, 0.25)),
    Palette(skyTop: rgb(0.10, 0.30, 0.34), skyBottom: rgb(0.70, 0.86, 0.62), sun: rgb(1, 0.95, 0.7), hills: rgb(0.06, 0.18, 0.14), bird: rgb(0.20, 0.52, 0.30), belly: rgb(0.96, 0.84, 0.30), accent: rgb(0.9, 0.2, 0.2)),
]

func rand(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo ... hi, using: &rng) }

func context() -> CGContext {
    CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func blur(_ image: CGImage, sigma: Double) -> CGImage {
    guard sigma > 0 else { return image }
    let input = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    return ci.createCGImage(input, from: input.extent) ?? image
}

func background(_ p: Palette, seed: Double) -> CGImage {
    let c = context()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: space, colors: [p.skyBottom, p.skyTop] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(H)), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [p.sun, p.sun.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: 1150 - seed * 400, y: 330), startRadius: 0, endCenter: CGPoint(x: 1150 - seed * 400, y: 330), endRadius: 520, options: [])
    c.setFillColor(p.hills)
    c.move(to: CGPoint(x: 0, y: 0))
    for x in stride(from: 0, through: W, by: 20) {
        c.addLine(to: CGPoint(x: Double(x), y: 210 + 70 * sin(Double(x) / 170 + seed * 6) + 38 * sin(Double(x) / 61 + seed)))
    }
    c.addLine(to: CGPoint(x: W, y: 0)); c.fillPath()
    // Soft foliage bokeh.
    for _ in 0 ..< 46 {
        c.setFillColor(p.accent.copy(alpha: rand(0.04, 0.16))!)
        let r = rand(20, 90)
        c.fillEllipse(in: CGRect(x: rand(0, Double(W)), y: rand(0, Double(H)), width: r, height: r))
    }
    return blur(c.makeImage()!, sigma: 9)
}

/// Draws a bird with plenty of fine feather detail so sharpness differences are measurable.
func drawBird(_ c: CGContext, at origin: CGPoint, scale: Double, wing: Double, tilt: Double, p: Palette, flying: Bool) {
    c.saveGState()
    c.translateBy(x: origin.x, y: origin.y)
    c.rotate(by: tilt)
    c.scaleBy(x: scale, y: scale)

    if !flying {   // branch
        c.setStrokeColor(rgb(0.16, 0.11, 0.08)); c.setLineWidth(22); c.setLineCap(.round)
        c.move(to: CGPoint(x: -420, y: -128)); c.addLine(to: CGPoint(x: 460, y: -118)); c.strokePath()
        c.setLineWidth(1.2)
        for i in 0 ..< 160 {
            c.setStrokeColor(rgb(0.05 + Double(i % 3) * 0.05, 0.04, 0.03))
            let x = -420 + Double(i) * 5.6
            c.move(to: CGPoint(x: x, y: -136)); c.addLine(to: CGPoint(x: x + 8, y: -112)); c.strokePath()
        }
    }
    // Wings
    c.setFillColor(p.bird)
    for side in [-1.0, 1.0] where flying || side > 0 {
        c.saveGState()
        c.rotate(by: wing * side * 0.9)
        c.move(to: CGPoint(x: 0, y: 20))
        c.addCurve(to: CGPoint(x: side * 330, y: 90 + wing * 120), control1: CGPoint(x: side * 120, y: 190), control2: CGPoint(x: side * 260, y: 160))
        c.addCurve(to: CGPoint(x: 0, y: -10), control1: CGPoint(x: side * 240, y: 20), control2: CGPoint(x: side * 100, y: -20))
        c.fillPath()
        c.restoreGState()
    }
    // Body, belly, tail
    c.setFillColor(p.bird); c.fillEllipse(in: CGRect(x: -86, y: -64, width: 190, height: 128))
    c.setFillColor(p.belly); c.fillEllipse(in: CGRect(x: -58, y: -62, width: 150, height: 74))
    c.setFillColor(p.bird)
    c.move(to: CGPoint(x: -70, y: 0)); c.addLine(to: CGPoint(x: -230, y: -30 - wing * 40)); c.addLine(to: CGPoint(x: -220, y: 22 - wing * 40)); c.closePath(); c.fillPath()
    // Head, beak, eye
    c.setFillColor(p.bird); c.fillEllipse(in: CGRect(x: 78, y: 18, width: 84, height: 84))
    c.setFillColor(rgb(0.08, 0.07, 0.06))
    c.move(to: CGPoint(x: 156, y: 66)); c.addLine(to: CGPoint(x: 238, y: 50)); c.addLine(to: CGPoint(x: 156, y: 44)); c.closePath(); c.fillPath()
    c.setFillColor(rgb(1, 1, 1)); c.fillEllipse(in: CGRect(x: 124, y: 62, width: 16, height: 16))
    c.setFillColor(rgb(0, 0, 0)); c.fillEllipse(in: CGRect(x: 129, y: 66, width: 8, height: 8))
    // Feather texture: dense, high-frequency strokes.
    c.setLineWidth(1)
    for i in 0 ..< 420 {
        let a = Double(i) * 2.399
        let r = 8 + Double(i % 70)
        let x = cos(a) * r * 1.5 + 10, y = sin(a) * r * 0.8
        c.setStrokeColor(i % 2 == 0 ? rgb(1, 1, 1, 0.55) : rgb(0, 0, 0, 0.45))
        c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + 9, y: y - 5)); c.strokePath()
    }
    c.restoreGState()
}

func frame(palette: Palette, bg: CGImage, birdX: Double, birdY: Double, wing: Double, tilt: Double, flying: Bool, defocus: Double, seed: Double) -> CGImage {
    let c = context()
    c.draw(bg, in: CGRect(x: 0, y: 0, width: W, height: H))
    drawBird(c, at: CGPoint(x: birdX, y: birdY), scale: flying ? 1.25 : 1.35, wing: wing, tilt: tilt, p: palette, flying: flying)
    // Grain so even "clean" frames have texture.
    for _ in 0 ..< 1500 {
        c.setFillColor(rgb(1, 1, 1, rand(0, 0.06)))
        c.fill(CGRect(x: rand(0, Double(W)), y: rand(0, Double(H)), width: 2, height: 2))
    }
    return blur(c.makeImage()!, sigma: defocus)
}

func jpeg(_ image: CGImage, quality: Double = 0.88) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// MARK: - Shoot plan

var clock = Date(timeIntervalSince1970: 1_793_000_000)   // an arbitrary early-morning timestamp
var number = 1
var written = 0

func write(_ image: CGImage, at time: Date, shutter: Int, iso: Int) throws {
    let name = String(format: "DSC%05d", number)
    number += 1
    var shot = SyntheticRAW.Shot(jpeg: jpeg(image), date: Date(timeIntervalSince1970: floor(time.timeIntervalSince1970)),
                                 subsecond: Int((time.timeIntervalSince1970 - floor(time.timeIntervalSince1970)) * 1000))
    shot.iso = iso
    shot.exposure = (1, shutter)
    shot.fNumber = (63, 10)
    try SyntheticRAW.make(shot).write(to: outURL.appendingPathComponent(name + ".ARW"))
    if pairs { try jpeg(image, quality: 0.92).write(to: outURL.appendingPathComponent(name + ".JPG")) }
    written += 1
}

// (frames, flying)
let plan: [(Int, Bool)] = [(1, false), (12, true), (1, false), (9, false), (14, true), (2, false), (7, true), (1, true), (11, false), (6, true), (1, false), (10, true)]

for (index, scene) in plan.enumerated() {
    let palette = palettes[index % palettes.count]
    let seed = rand(0, 1)
    let bg = background(palette, seed: seed)
    clock = clock.addingTimeInterval(rand(25, 140))
    let (count, flying) = scene
    let sharpFrames = Set((0 ..< count).shuffled(using: &rng).prefix(max(1, count / 5)))
    var x = rand(520, 760), y = rand(430, 600)

    for f in 0 ..< count {
        let phase = sin(Double(f) * 0.9)
        x += flying ? rand(18, 46) : rand(-6, 6)
        y += flying ? rand(-14, 14) : rand(-2, 2)
        let defocus: Double = sharpFrames.contains(f) ? 0 : [1.1, 1.8, 2.6, 3.8, 5.5].randomElement(using: &rng)!
        let img = frame(palette: palette, bg: bg, birdX: x, birdY: y, wing: flying ? phase * 0.6 : 0, tilt: flying ? rand(-0.12, 0.12) : 0,
                        flying: flying, defocus: defocus, seed: seed)
        try write(img, at: clock, shutter: flying ? 3200 : 1250, iso: flying ? 1600 : 800)
        clock = clock.addingTimeInterval(count == 1 ? 0 : 0.09)   // ~11 fps bursts
    }
    print("scene \(index + 1)/\(plan.count): \(count) frame\(count == 1 ? "" : "s")")
}
print("Wrote \(written) synthetic ARW files to \(outURL.path)")
