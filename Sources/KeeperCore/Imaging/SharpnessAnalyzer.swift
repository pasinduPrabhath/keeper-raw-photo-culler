import CoreGraphics
import Foundation

/// Scores how sharp the *sharpest region* of an image is.
///
/// Wildlife shots have a razor-sharp subject against a deliberately blurry background, so a global
/// blur metric would punish exactly the frames you want. Instead the image is cut into tiles, the
/// variance of the Laplacian is measured per tile, and the score is the mean of the top 5% of tiles.
/// A motion-blurred or missed-focus frame has no sharp tiles at all and scores low.
///
/// Scores are only comparable between frames of the same scene (i.e. inside one burst).
public enum SharpnessAnalyzer {
    public static func score(_ image: CGImage, maxDimension: Int = 1024, tileSize: Int = 16) -> Double {
        let scale = min(1.0, Double(maxDimension) / Double(max(image.width, image.height)))
        let w = max(tileSize * 2, Int((Double(image.width) * scale).rounded()))
        let h = max(tileSize * 2, Int((Double(image.height) * scale).rounded()))

        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }

        let tilesX = w / tileSize, tilesY = h / tileSize
        var sums = [Double](repeating: 0, count: tilesX * tilesY)
        var squares = [Double](repeating: 0, count: tilesX * tilesY)
        var counts = [Double](repeating: 0, count: tilesX * tilesY)

        pixels.withUnsafeBufferPointer { px in
            for y in 1 ..< (h - 1) {
                let ty = y / tileSize
                if ty >= tilesY { break }
                for x in 1 ..< (w - 1) {
                    let tx = x / tileSize
                    if tx >= tilesX { break }
                    let i = y * w + x
                    let lap = 4 * Int(px[i]) - Int(px[i - 1]) - Int(px[i + 1]) - Int(px[i - w]) - Int(px[i + w])
                    let d = Double(lap)
                    let t = ty * tilesX + tx
                    sums[t] += d
                    squares[t] += d * d
                    counts[t] += 1
                }
            }
        }

        var variances: [Double] = []
        variances.reserveCapacity(sums.count)
        for t in 0 ..< sums.count where counts[t] > Double(tileSize * tileSize) / 2 {
            let mean = sums[t] / counts[t]
            variances.append(squares[t] / counts[t] - mean * mean)
        }
        guard !variances.isEmpty else { return 0 }
        variances.sort(by: >)
        let top = max(1, variances.count / 20)
        return variances.prefix(top).reduce(0, +) / Double(top)
    }
}
