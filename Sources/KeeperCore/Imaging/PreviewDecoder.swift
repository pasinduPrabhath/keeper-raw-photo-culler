import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Turns a photo on disk into a `CGImage` as cheaply as possible.
///
/// Order of preference:
/// 1. the companion JPEG (RAW+JPEG shooters get full resolution, and it's fast),
/// 2. the JPEG embedded in the RAW (parsed by `TIFFPreviewExtractor`),
/// 3. ImageIO's own RAW path (slow; last resort for non-TIFF containers such as CR3 or RAF).
public enum PreviewDecoder {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Best quickly-available image, downsampled so its long edge is at most `maxPixel`.
    public static func image(primary: URL, companion: URL?, maxPixel: Int) -> CGImage? {
        if let companion, let image = decodeFile(companion, maxPixel: maxPixel) { return image }
        guard FileTypes.isRaw(primary) else { return decodeFile(primary, maxPixel: maxPixel) }
        if let image = decodeEmbedded(primary, maxPixel: maxPixel) { return image }
        return decodeFile(primary, maxPixel: maxPixel, fromRAW: true)
    }

    /// The raw bytes of the largest JPEG embedded in a RAW file, if the container is TIFF-based.
    public static func embeddedJPEG(in url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return TIFFPreviewExtractor.largestJPEG(in: data)
    }

    /// Full-resolution image for 100% focus checking.
    /// Uses the companion JPEG, else a large embedded JPEG, else develops the RAW with Core Image (slow).
    public static func fullResolution(primary: URL, companion: URL?) -> CGImage? {
        if let companion, let image = decodeFile(companion, maxPixel: 100_000) { return image }
        guard FileTypes.isRaw(primary) else { return decodeFile(primary, maxPixel: 100_000) }
        // Many bodies (e.g. Sony A6700) embed a full-resolution JPEG: instant, and it matches the camera's look.
        if let embedded = decodeEmbedded(primary, maxPixel: 100_000), max(embedded.width, embedded.height) >= 3000 { return embedded }
        return developRAW(primary)
    }

    /// Develops a RAW with Apple's RAW engine. Neutral-looking, not the camera's JPEG style.
    public static func developRAW(_ url: URL, maxPixel: Int? = nil) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url), var output = filter.outputImage else { return nil }
        if let maxPixel {
            let longEdge = max(output.extent.width, output.extent.height)
            if longEdge > CGFloat(maxPixel) {
                let s = CGFloat(maxPixel) / longEdge
                output = output.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        return ciContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: space)
    }

    // MARK: - Internals

    static func decodeFile(_ url: URL, maxPixel: Int, fromRAW: Bool = false) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source, maxPixel: maxPixel, transform: true, always: !fromRAW)
    }

    static func decodeEmbedded(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let jpeg = embeddedJPEG(in: url),
              let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }

        // Cameras usually leave the orientation on the RAW's own IFD, not on the embedded JPEG.
        let jpegOrientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1
        guard let image = thumbnail(source, maxPixel: maxPixel, transform: true, always: true) else { return nil }
        if jpegOrientation > 1 { return image }

        let rawOrientation = MetadataReader.properties(url)?[kCGImagePropertyOrientation] as? Int ?? 1
        return rawOrientation > 1 ? oriented(image, exif: rawOrientation) : image
    }

    static func thumbnail(_ source: CGImageSource, maxPixel: Int, transform: Bool, always: Bool) -> CGImage? {
        let options: [CFString: Any] = [
            always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: transform,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Applies an EXIF orientation (1–8) to the pixels.
    public static func oriented(_ image: CGImage, exif: Int) -> CGImage {
        guard exif > 1, exif <= 8 else { return image }
        let ci = CIImage(cgImage: image).oriented(forExifOrientation: Int32(exif))
        return ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)) ?? image
    }
}

public enum ImageResizer {
    /// Resizes so the long edge is at most `maxPixel`. Returns the input when it is already small enough.
    public static func resize(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longEdge)
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
