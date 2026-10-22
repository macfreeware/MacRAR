import Foundation

/// Arşiv dosya adı üretimi: kaynak adından ad, isteğe bağlı zaman damgası, çakışmada numara.
public enum ArchiveNaming {
    public struct StampFormat: Identifiable, Hashable, Sendable {
        /// Unicode tarih deseni (DateFormatter), örn. "yyyyMMddHHmmss".
        public let pattern: String
        public var id: String { pattern }
        public init(_ pattern: String) { self.pattern = pattern }
    }

    /// Hazır zaman damgası biçimleri (kullanıcı ayrıca özel desen yazabilir).
    public static let presets: [StampFormat] = [
        StampFormat("yyyyMMddHHmmss"),
        StampFormat("yyyyMMdd-HHmmss"),
        StampFormat("yyyy-MM-dd_HH-mm-ss"),
        StampFormat("yyyy-MM-dd HH.mm.ss"),
        StampFormat("dd-MM-yyyy_HH-mm"),
        StampFormat("yyyyMMdd"),
        StampFormat("yyyy-MM-dd"),
        StampFormat("yyMMdd_HHmm"),
    ]

    public static let defaultPattern = "yyyyMMddHHmmss"
    public static let defaultSeparator = "-"
    public static let separators: [String] = ["-", "_", " ", ""]

    /// Deseni verilen tarihe uygular. Sonuçtaki dosya adında geçersiz olan karakterler ("/" ve ":") "-" olur.
    public static func timestamp(pattern: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = pattern
        return sanitize(f.string(from: date))
    }

    /// Desen boş olmayan, dosya adına uygun bir damga üretiyorsa true.
    public static func isValid(pattern: String) -> Bool {
        let t = timestamp(pattern: pattern)
        return !pattern.trimmingCharacters(in: .whitespaces).isEmpty
            && !t.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Kaynaklardan arşiv adı tabanı: tek öğede öğenin adı (dosyada uzantısız), birden çokta üst klasör adı.
    public static func baseName(for sources: [URL]) -> String {
        guard let first = sources.first else { return String(localized: "Arşiv") }
        var name: String
        if sources.count == 1 {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            name = isDir.boolValue ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
        } else {
            name = first.deletingLastPathComponent().lastPathComponent
        }
        name = sanitize(name).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "/" ? String(localized: "Arşiv") : name
    }

    /// "klasör.rar" veya "klasör-20261009112345.rar".
    public static func fileName(base: String, stamp: (pattern: String, separator: String)?,
                                ext: String, date: Date = Date()) -> String {
        var name = base
        if let stamp { name += stamp.separator + timestamp(pattern: stamp.pattern, date: date) }
        return name + "." + ext
    }

    /// Hedef klasörde aynı ad varsa "ad 2.rar", "ad 3.rar"… (var olan arşive yanlışlıkla eklemeyi önler).
    public static func uniqueURL(in directory: URL, fileName: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let stem = String(fileName.dropLast(ext.count + 1))
        var n = 2
        repeat {
            candidate = directory.appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
