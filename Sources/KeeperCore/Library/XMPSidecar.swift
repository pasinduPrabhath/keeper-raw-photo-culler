import Foundation

/// Writes ratings/labels to `.xmp` sidecars so Lightroom, Capture One, darktable etc. pick them up.
/// An existing sidecar is patched in place so develop settings are never lost.
public enum XMPSidecar {
    public static func url(for primary: URL) -> URL { primary.deletingPathExtension().appendingPathExtension("xmp") }

    /// - Parameters:
    ///   - rating: 0–5 stars, or -1 for "rejected" (the XMP convention).
    ///   - label: colour label such as "Green", or nil for none.
    public static func write(for primary: URL, rating: Int, label: String?) throws {
        let target = url(for: primary)
        if let existing = try? String(contentsOf: target, encoding: .utf8) {
            if let patched = patch(existing, rating: rating, label: label) {
                try patched.write(to: target, atomically: true, encoding: .utf8)
            }
            return
        }
        // Don't litter the folder with empty sidecars.
        guard rating != 0 || label != nil else { return }
        try template(rating: rating, label: label).write(to: target, atomically: true, encoding: .utf8)
    }

    static func template(rating: Int, label: String?) -> String {
        let labelAttr = label.map { "\n   xmp:Label=\"\($0)\"" } ?? ""
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Keeper">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:xmp="http://ns.adobe.com/xap/1.0/"
           xmp:Rating="\(rating)"\(labelAttr)/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    static func patch(_ xml: String, rating: Int, label: String?) -> String? {
        var out = xml
        out = setAttribute("xmp:Rating", value: String(rating), in: out) ?? out
        guard out.contains("xmp:Rating=\"\(rating)\"") else { return nil }
        if let label {
            out = setAttribute("xmp:Label", value: label, in: out) ?? out
        } else if let range = out.range(of: #"\s*xmp:Label="[^"]*""#, options: .regularExpression) {
            out.removeSubrange(range)
        }
        return out
    }

    private static func setAttribute(_ name: String, value: String, in xml: String) -> String? {
        if let range = xml.range(of: "\(name)=\"[^\"]*\"", options: .regularExpression) {
            var copy = xml
            copy.replaceSubrange(range, with: "\(name)=\"\(value)\"")
            return copy
        }
        guard let open = xml.range(of: "<rdf:Description") else { return nil }
        var copy = xml
        var insertion = " \(name)=\"\(value)\""
        if !xml.contains("xmlns:xmp=") { insertion = " xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"" + insertion }
        copy.insert(contentsOf: insertion, at: open.upperBound)
        return copy
    }
}

public struct PhotoState: Codable, Equatable, Sendable {
    public var flag: Flag
    public var rating: Int
    public init(flag: Flag = .none, rating: Int = 0) { self.flag = flag; self.rating = rating }
    public var isDefault: Bool { flag == .none && rating == 0 }
}

/// Remembers picks / rejects / stars per folder so closing the app loses nothing.
public enum StateStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keeper/State", isDirectory: true)
    }

    private static func file(for folder: URL) -> URL {
        let name = folder.standardizedFileURL.path.utf8.reduce(into: UInt64(14695981039346656037)) { h, b in h = (h ^ UInt64(b)) &* 1099511628211 }
        return directory.appendingPathComponent(String(name, radix: 16) + ".json")
    }

    public static func load(folder: URL) -> [String: PhotoState] {
        guard let data = try? Data(contentsOf: file(for: folder)) else { return [:] }
        return (try? JSONDecoder().decode([String: PhotoState].self, from: data)) ?? [:]
    }

    public static func save(_ states: [String: PhotoState], folder: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let compact = states.filter { !$0.value.isDefault }
        if let data = try? JSONEncoder().encode(compact) { try? data.write(to: file(for: folder), options: .atomic) }
    }
}
