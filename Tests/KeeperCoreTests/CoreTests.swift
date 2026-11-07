import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import KeeperCore

@Suite struct TIFFPreviewTests {
    @Test func findsJPEGInNonTIFFContainer() {
        // Mimics a Canon CR3 / Fuji RAF: no TIFF header, a JPEG somewhere inside an opaque container.
        let jpeg = TestImages.jpegData(TestImages.sharp())
        var file = Data([0, 0, 0, 24]) + Data("ftypcrx ".utf8) + Data(repeating: 0x11, count: 5000)
        file += jpeg
        #expect(TIFFPreviewExtractor.largestJPEG(in: file)?.starts(with: jpeg.prefix(1024)) == true)
    }

    @Test func findsJPEGInSubIFDStrip() throws {
        let jpeg = TestImages.jpegData(TestImages.sharp())
        let raw = SyntheticRAW.make(.init(jpeg: jpeg, date: Date(), subsecond: 0))
        let found = TIFFPreviewExtractor.largestJPEG(in: raw)
        #expect(found == jpeg)
    }

    @Test func findsJPEGInterchangeFormatTags() throws {
        let jpeg = TestImages.jpegData(TestImages.sharp())
        var shot = SyntheticRAW.Shot(jpeg: jpeg, date: Date())
        shot.useJPEGInterchangeTags = true
        #expect(TIFFPreviewExtractor.largestJPEG(in: SyntheticRAW.make(shot)) == jpeg)
    }

    /// Regression test for a real Sony A6700 file: the biggest "JPEG" is lossless sensor data (SOF3).
    @Test func ignoresLosslessSensorDataStream() {
        let baseline = TestImages.jpegData(TestImages.sharp())
        var lossless = Data([0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x0B, 0x08, 0x10, 0x00, 0x10, 0x00, 0x01, 0x01, 0x11, 0x00])
        lossless.append(Data(repeating: 0x42, count: baseline.count * 8))   // much bigger than the real preview

        var b = TIFFBuilder()
        b.ifds = [
            .init(name: "ifd0", entries: [.init(0x014A, .ifdOffset("raw")), .init(0x0103, .short(6)),
                                          .init(0x0201, .blobOffset("preview")), .init(0x0202, .blobLength("preview"))], next: nil),
            .init(name: "raw", entries: [.init(0x0103, .short(7)), .init(0x0111, .blobOffset("sensor")), .init(0x0117, .blobLength("sensor"))], next: nil),
        ]
        b.blobs = [("preview", baseline), ("sensor", lossless)]
        let file = b.build()
        let candidates = TIFFPreviewExtractor.candidates(in: file)
        #expect(candidates.count == 1)
        #expect(TIFFPreviewExtractor.largestJPEG(in: file) == baseline)
    }

    @Test func rejectsGarbage() {
        #expect(TIFFPreviewExtractor.candidates(in: Data(repeating: 0x41, count: 4096)).isEmpty)
        #expect(TIFFPreviewExtractor.candidates(in: Data()).isEmpty)
    }

    @Test func survivesTruncatedAndCorruptFiles() {
        let jpeg = TestImages.jpegData(TestImages.sharp())
        let raw = SyntheticRAW.make(.init(jpeg: jpeg, date: Date()))
        for cut in stride(from: 0, to: 400, by: 7) { _ = TIFFPreviewExtractor.candidates(in: raw.prefix(cut)) }
        var corrupt = raw
        for i in stride(from: 8, to: 300, by: 3) { corrupt[i] = 0xFF }
        _ = TIFFPreviewExtractor.candidates(in: corrupt)   // must not crash
    }

    @Test func decodesPreviewFromSyntheticFile() throws {
        let dir = temporaryDirectory()
        let url = dir.appendingPathComponent("DSC00001.ARW")
        try SyntheticRAW.make(.init(jpeg: TestImages.jpegData(TestImages.sharp()), date: Date())).write(to: url)
        let image = PreviewDecoder.image(primary: url, companion: nil, maxPixel: 800)
        #expect(image != nil)
        #expect(max(image?.width ?? 0, image?.height ?? 0) == 800)
    }

    @Test func appliesRawOrientationToUprightPreview() throws {
        let dir = temporaryDirectory()
        let url = dir.appendingPathComponent("DSC00002.ARW")
        var shot = SyntheticRAW.Shot(jpeg: TestImages.jpegData(TestImages.sharp()), date: Date())
        shot.orientation = 6   // rotate 90° CW
        try SyntheticRAW.make(shot).write(to: url)
        let image = try #require(PreviewDecoder.image(primary: url, companion: nil, maxPixel: 2000))
        #expect(image.height > image.width)
    }
}

@Suite struct MetadataTests {
    @Test func readsExifFromSyntheticRAW() throws {
        let dir = temporaryDirectory()
        let url = dir.appendingPathComponent("DSC00003.ARW")
        let date = MetadataReader.parseExifDate("2026:11:07 09:42:11", subsec: "47")!
        var shot = SyntheticRAW.Shot(jpeg: TestImages.jpegData(TestImages.sharp()), date: date, subsecond: 470)
        shot.iso = 1600
        try SyntheticRAW.make(shot).write(to: url)

        let meta = MetadataReader.read(url, fallbackDate: .distantPast)
        #expect(meta.iso == 1600)
        #expect(meta.model == "ILCE-6700")
        #expect(meta.shutterText == "1/2000")
        #expect(meta.focalText == "600 mm")
        #expect(abs(meta.captureDate.timeIntervalSince(date) - 0) < 0.01)
    }

    @Test func parsesSubseconds() {
        let a = MetadataReader.parseExifDate("2026:11:07 09:42:11", subsec: nil)!
        let b = MetadataReader.parseExifDate("2026:11:07 09:42:11", subsec: "25")!
        let c = MetadataReader.parseExifDate("2026:11:07 09:42:11", subsec: "125")!
        #expect(abs(b.timeIntervalSince(a) - 0.25) < 1e-6)
        #expect(abs(c.timeIntervalSince(a) - 0.125) < 1e-6)
        #expect(MetadataReader.parseExifDate("garbage", subsec: nil) == nil)
    }
}

@Suite struct BurstTests {
    @Test func splitsOnGap() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let times = [0, 0.09, 0.18, 0.27, 5, 5.1, 20].map { t0.addingTimeInterval($0) }
        #expect(BurstGrouper.assign(dates: times, maxGap: 1.0) == [0, 0, 0, 0, 1, 1, 2])
    }

    @Test func emptyAndSingle() {
        #expect(BurstGrouper.assign(dates: [], maxGap: 1).isEmpty)
        #expect(BurstGrouper.assign(dates: [Date()], maxGap: 1) == [0])
    }
}

@Suite struct SharpnessTests {
    @Test func sharpBeatsBlurry() {
        let sharp = TestImages.sharp()
        let soft = TestImages.blurred(sharp, radius: 3)
        let mush = TestImages.blurred(sharp, radius: 9)
        let a = SharpnessAnalyzer.score(sharp), b = SharpnessAnalyzer.score(soft), c = SharpnessAnalyzer.score(mush)
        #expect(a > b)
        #expect(b > c)
    }

    @Test func sharpSubjectOnBlurryBackgroundStillWins() {
        // Half the frame sharp, half blurred, versus a fully blurred frame.
        let sharp = TestImages.sharp()
        let blurred = TestImages.blurred(sharp, radius: 8)
        let ctx = CGContext(data: nil, width: sharp.width, height: sharp.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(blurred, in: CGRect(x: 0, y: 0, width: sharp.width, height: sharp.height))
        ctx.draw(sharp.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 300))!, in: CGRect(x: 0, y: 0, width: 300, height: 300))
        let subject = ctx.makeImage()!
        #expect(SharpnessAnalyzer.score(subject) > SharpnessAnalyzer.score(blurred) * 3)
    }
}

@Suite struct ScannerTests {
    @Test func pairsRawWithJPEGAndSidecars() throws {
        let dir = temporaryDirectory()
        for name in ["DSC001.ARW", "DSC001.JPG", "DSC001.xmp", "DSC002.ARW", "DSC003.JPG", "notes.txt", ".hidden.ARW"] {
            try Data([1, 2, 3]).write(to: dir.appendingPathComponent(name))
        }
        let files = FolderScanner.scan(dir)
        #expect(files.count == 3)
        let first = try #require(files.first { $0.url.lastPathComponent == "DSC001.ARW" })
        #expect(first.companion?.lastPathComponent == "DSC001.JPG")
        #expect(first.sidecars.count == 1)
        #expect(first.allFiles.count == 3)
        #expect(files.contains { $0.url.lastPathComponent == "DSC003.JPG" && !$0.isRaw })
    }
}

@Suite struct XMPTests {
    @Test func createsAndPatchesSidecar() throws {
        let dir = temporaryDirectory()
        let raw = dir.appendingPathComponent("A.ARW")
        try XMPSidecar.write(for: raw, rating: 0, label: nil)
        #expect(!FileManager.default.fileExists(atPath: XMPSidecar.url(for: raw).path))   // no empty sidecars

        try XMPSidecar.write(for: raw, rating: 4, label: "Green")
        var text = try String(contentsOf: XMPSidecar.url(for: raw))
        #expect(text.contains("xmp:Rating=\"4\"") && text.contains("xmp:Label=\"Green\""))

        try XMPSidecar.write(for: raw, rating: -1, label: nil)
        text = try String(contentsOf: XMPSidecar.url(for: raw))
        #expect(text.contains("xmp:Rating=\"-1\"") && !text.contains("xmp:Label"))
    }

    @Test func preservesForeignSettings() throws {
        let dir = temporaryDirectory()
        let raw = dir.appendingPathComponent("B.ARW")
        let lightroom = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.65"/>
        </rdf:RDF></x:xmpmeta>
        """
        try lightroom.write(to: XMPSidecar.url(for: raw), atomically: true, encoding: .utf8)
        try XMPSidecar.write(for: raw, rating: 3, label: nil)
        let text = try String(contentsOf: XMPSidecar.url(for: raw))
        #expect(text.contains("crs:Exposure2012=\"+0.65\""))
        #expect(text.contains("xmp:Rating=\"3\""))
        #expect(text.contains("xmlns:xmp="))
    }
}

@Suite struct DriveHelperTests {
    @Test func pkceMatchesRFC7636Example() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let v = PKCE.randomVerifier()
        #expect(v.count == 64 && v.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(GoogleAuth.formEncode(["a": "x y&z", "b": "1/2"]) == "a=x%20y%26z&b=1%2F2")
    }

    @Test func queryEscapingHandlesQuotes() {
        #expect(DriveClient.escape("Bob's \"trip\"") == "Bob\\'s \"trip\"")
    }
}

@Suite struct ThumbnailServiceTests {
    @Test func computesCachesAndReusesAnalysis() async throws {
        let dir = temporaryDirectory()
        let url = dir.appendingPathComponent("DSC00009.ARW")
        try SyntheticRAW.make(.init(jpeg: TestImages.jpegData(TestImages.sharp()), date: Date())).write(to: url)
        let cache = dir.appendingPathComponent("cache")
        let service = ThumbnailService(directory: cache)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try #require(await service.analysis(primary: url, companion: nil, size: 100, modified: modified))
        #expect(max(first.thumbnail.width, first.thumbnail.height) <= ThumbnailService.thumbnailPixels)
        #expect(first.sharpness > 0)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).count == 2)

        // A fresh service must hit the disk cache and report the same score.
        let again = try #require(await ThumbnailService(directory: cache).analysis(primary: url, companion: nil, size: 100, modified: modified))
        #expect(abs(again.sharpness - first.sharpness) < 1e-6)
    }
}
