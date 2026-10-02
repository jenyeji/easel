import Foundation
import CoreGraphics

// MARK: - Corners

/// The four corners of the painting, stored as fractions of the photo (0...1).
/// (0, 0) is the top-left of the photo, (1, 1) is the bottom-right.
struct Quad: Equatable, Codable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// A starting guess: a rectangle slightly inside the photo.
    static let inset = Quad(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomRight: CGPoint(x: 0.9, y: 0.9),
        bottomLeft: CGPoint(x: 0.1, y: 0.9)
    )

    subscript(corner: Corner) -> CGPoint {
        get {
            switch corner {
            case .topLeft: return topLeft
            case .topRight: return topRight
            case .bottomRight: return bottomRight
            case .bottomLeft: return bottomLeft
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomRight: bottomRight = newValue
            case .bottomLeft: bottomLeft = newValue
            }
        }
    }

    /// True when the painting outlined by these corners is wider than it is tall.
    /// `imageSize` is needed because the corners are stored as fractions.
    func looksLandscape(imageSize: CGSize) -> Bool {
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = (a.x - b.x) * imageSize.width
            let dy = (a.y - b.y) * imageSize.height
            return (dx * dx + dy * dy).squareRoot()
        }
        let width = (dist(topLeft, topRight) + dist(bottomLeft, bottomRight)) / 2
        let height = (dist(topLeft, bottomLeft) + dist(topRight, bottomRight)) / 2
        return width > height
    }
}

enum Corner: CaseIterable, Identifiable {
    case topLeft, topRight, bottomRight, bottomLeft
    var id: Self { self }
}

// MARK: - Sizes

enum Orientation: String, CaseIterable, Identifiable, Codable {
    case portrait, landscape
    var id: Self { self }
    var label: String { self == .portrait ? "Portrait" : "Landscape" }
}

/// A canvas size such as 11 x 14. Stored as short side and long side,
/// so the same preset works for portrait and landscape paintings.
struct SizePreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var short: Double
    var long: Double

    var label: String { "\(SizePreset.format(short))x\(SizePreset.format(long))" }

    static func format(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static let defaults: [SizePreset] = {
        let pairs: [(Double, Double)] = [
            (5, 7), (8, 8), (8, 10), (9, 12), (11, 14), (12, 12), (12, 16),
            (16, 20), (18, 24), (20, 24), (24, 30), (24, 36), (30, 40), (36, 48)
        ]
        return pairs.map { SizePreset(short: $0.0, long: $0.1) }
    }()
}

// MARK: - Per-photo edits

struct PhotoEdit: Equatable, Codable {
    var title = ""
    /// Left empty to use the default artist from Settings.
    var artist = ""
    /// When the painting was made. Month is optional: 0 means no month, 1–12 are January–December.
    var month = 0
    var year = Calendar.current.component(.year, from: Date())
    var medium = ""
    var recordID = ""
    /// A file name typed for this photo only. Empty means "use the naming style".
    var customFileName = ""
    var presetID: UUID?
    var useCustomSize = false
    var customShort: Double = 11
    var customLong: Double = 14
    var orientation: Orientation = .portrait
    var quad: Quad?

    /// "2026-09" (or just "2026" with no month), used for {date} in file names.
    var dateForFileName: String {
        month == 0 ? String(year) : String(format: "%04d-%02d", year, month)
    }

    /// "September 2026", or just "2026" with no month.
    static func readableDate(month: Int, year: Int) -> String {
        month == 0 ? String(year) : monthName(month) + " \(year)"
    }

    static func monthName(_ month: Int) -> String {
        let names = Calendar.current.monthSymbols
        return names[min(max(month, 1), 12) - 1]
    }

    /// Short side and long side for the chosen size.
    func sides(presets: [SizePreset]) -> (short: Double, long: Double)? {
        if useCustomSize {
            let a = customShort, b = customLong
            guard a > 0, b > 0 else { return nil }
            return (min(a, b), max(a, b))
        }
        guard let id = presetID, let preset = presets.first(where: { $0.id == id }) else { return nil }
        return (preset.short, preset.long)
    }

    /// Width : height of the finished image.
    func aspect(presets: [SizePreset]) -> (width: Double, height: Double)? {
        guard let s = sides(presets: presets) else { return nil }
        return orientation == .portrait ? (s.short, s.long) : (s.long, s.short)
    }

    func sizeLabel(presets: [SizePreset]) -> String {
        guard let s = sides(presets: presets) else { return "" }
        return "\(SizePreset.format(s.short))x\(SizePreset.format(s.long))"
    }

    /// A fresh edit for the next photo that keeps the settings that usually stay the same.
    func carriedOver() -> PhotoEdit {
        var next = PhotoEdit()
        next.artist = artist
        next.month = month
        next.year = year
        next.medium = medium
        next.presetID = presetID
        next.useCustomSize = useCustomSize
        next.customShort = customShort
        next.customLong = customLong
        next.orientation = orientation
        return next
    }
}

/// A photo in the list on the left. The list is saved, so it's still there next time you open Easel.
struct PhotoItem: Identifiable, Codable {
    var id = UUID()
    let url: URL
    var edit: PhotoEdit?
    /// Where the JPGs were last saved, and what the edit looked like at that moment.
    var savedFullURL: URL?
    var savedWebURL: URL?
    var savedEdit: PhotoEdit?

    var savedName: String? { savedFullURL?.lastPathComponent }

    var name: String { url.lastPathComponent }
}

// MARK: - File names

struct NameToken: Identifiable {
    let token: String
    let label: String
    let help: String
    var id: String { token }
}

enum NameBuilder {
    /// The blanks people can use in the naming pattern.
    static let tokens: [NameToken] = [
        NameToken(token: "{title}", label: "Title", help: "Painting title"),
        NameToken(token: "{date}", label: "Date", help: "The painting's date, like 2026-09 (just 2026 if there's no month)"),
        NameToken(token: "{year}", label: "Year", help: "The painting's year, like 2026"),
        NameToken(token: "{artist}", label: "Artist", help: "Artist name"),
        NameToken(token: "{size}", label: "Size", help: "Canvas size, like 11x14"),
        NameToken(token: "{medium}", label: "Medium", help: "Medium, like oil"),
        NameToken(token: "{record}", label: "Record ID", help: "Your own number for the painting, like JS-014"),
        NameToken(token: "{today}", label: "Today", help: "The date you save, like 2026-09-30"),
        NameToken(token: "{original}", label: "Camera Name", help: "Camera file name, like DSC_0421")
    ]

    /// Ready-made naming styles to pick from.
    static let presets: [String] = [
        "{title}_{size}_{year}",
        "{title}_{date}_{artist}",
        "{artist}_{title}_{year}",
        "{record}_{title}",
        "{title}_{year}",
        "{original}"
    ]

    /// "{title}_{date}_{artist}" becomes "Title_Date_Artist", easier to read in menus.
    static func readable(_ pattern: String) -> String {
        var text = pattern
        for item in tokens {
            text = text.replacingOccurrences(of: item.token, with: item.label)
        }
        return text.isEmpty ? "(empty)" : text
    }

    /// Tidies a file name typed by hand: removes characters files can't have and a typed ".jpg".
    static func cleanFileName(_ text: String) -> String {
        var name = removeUnsafeCharacters(text).trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".jpg", ".jpeg"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    static func build(pattern: String, values: [String: String], separator: String, lowercase: Bool) -> String {
        var name = pattern
        for (key, raw) in values {
            name = name.replacingOccurrences(of: "{\(key)}", with: clean(raw, separator: separator))
        }
        // Remove any blanks that weren't recognised.
        name = name.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        name = removeUnsafeCharacters(name)
        if lowercase { name = name.lowercased() }

        // Tidy up doubled or dangling separators left by empty blanks.
        for sep in ["-", "_", " ", "."] {
            while name.contains(sep + sep) {
                name = name.replacingOccurrences(of: sep + sep, with: sep)
            }
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_ ."))
        return name
    }

    /// Turn "Sunset over Pescadero" into "Sunset-over-Pescadero" (for a dash separator).
    private static func clean(_ text: String, separator: String) -> String {
        let words = removeUnsafeCharacters(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return words.joined(separator: separator)
    }

    private static func removeUnsafeCharacters(_ text: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>#{}")
            .union(.controlCharacters)
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !unsafe.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

extension PhotoEdit {
    /// Reads a saved edit. Anything missing (say, from an older version of Easel) gets its usual default,
    /// so adding new fields later never throws away your saved photos.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PhotoEdit()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.init()
        title = value(.title, defaults.title)
        artist = value(.artist, defaults.artist)
        month = value(.month, defaults.month)
        year = value(.year, defaults.year)
        medium = value(.medium, defaults.medium)
        recordID = value(.recordID, defaults.recordID)
        customFileName = value(.customFileName, defaults.customFileName)
        presetID = value(.presetID, defaults.presetID)
        useCustomSize = value(.useCustomSize, defaults.useCustomSize)
        customShort = value(.customShort, defaults.customShort)
        customLong = value(.customLong, defaults.customLong)
        orientation = value(.orientation, defaults.orientation)
        quad = value(.quad, defaults.quad)
    }
}
