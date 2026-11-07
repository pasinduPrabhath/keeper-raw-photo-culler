import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ExportOptions: Sendable {
    public enum Source: String, Sendable, CaseIterable {
        /// The camera's own JPEG (companion or embedded): instant, keeps your in-camera look.
        case cameraPreview
        /// Develop the RAW with Apple's RAW engine: slower, full resolution, neutral look.
        case developedRAW
    }

    public var source: Source
    /// Long-edge limit in pixels; nil keeps the full size available.
    public var maxPixel: Int?
    public var quality: Double

    public init(source: Source = .cameraPreview, maxPixel: Int? = 2048, quality: Double = 0.88) {
        self.source = source; self.maxPixel = maxPixel; self.quality = quality
    }
}

public enum ExportError: Error, LocalizedError {
    case decodeFailed(String)
    case writeFailed(String)
    public var errorDescription: String? {
        switch self {
        case .decodeFailed(let n): "Couldn't read “\(n)”."
        case .writeFailed(let n): "Couldn't write “\(n)”."
        }
    }
}

/// Turns RAW files into shareable JPEGs without opening an editor.
public enum JPEGExporter {
    @discardableResult
    public static func export(primary: URL, companion: URL?, to destination: URL, options: ExportOptions) throws -> URL {
        let limit = options.maxPixel ?? 100_000
        let image: CGImage?
        switch options.source {
        case .cameraPreview:
            image = PreviewDecoder.image(primary: primary, companion: companion, maxPixel: limit)
        case .developedRAW:
            if FileTypes.isRaw(primary) {
                image = PreviewDecoder.developRAW(primary, maxPixel: options.maxPixel)
            } else {
                image = PreviewDecoder.image(primary: primary, companion: companion, maxPixel: limit)
            }
        }
        guard let image else { throw ExportError.decodeFailed(primary.lastPathComponent) }

        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: options.quality]
        if let original = MetadataReader.properties(primary) {
            // Pixels are already upright, so reset orientation; keep EXIF/TIFF for date, lens, exposure.
            if let exif = original[kCGImagePropertyExifDictionary] { props[kCGImagePropertyExifDictionary] = exif }
            if var tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            props[kCGImagePropertyOrientation] = 1
        }

        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExportError.writeFailed(destination.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writeFailed(destination.lastPathComponent) }
        return destination
    }
}
