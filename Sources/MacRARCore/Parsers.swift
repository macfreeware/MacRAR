import Foundation

// MARK: - rar/unrar "lt" (teknik liste) ayrıştırıcısı

public enum RarListParser {
    public struct Result: Sendable {
        public var entries: [ArchiveEntry]
        public var info: ArchiveInfo
        /// Çıktıda parola reddi/istemi görüldü.
        public var passwordProblem: Bool
        /// "Archive:" satırı görüldü (dosya geçerli bir RAR arşivi olarak açıldı).
        public var recognizedArchive: Bool
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        // "2026-10-09 10:20:07,594972898" -> saniyeye kadar al
        let trimmed = s.prefix(19)
        return dateFormatter.date(from: String(trimmed))
    }

    public static func parse(_ text: String) -> Result {
        var entries: [ArchiveEntry] = []
        var info = ArchiveInfo()
        var passwordProblem = false
        var recognized = false

        var block: [String: String] = [:]
        var sawArchiveLine = false
        // "Archive:" satırından önceki serbest metin (UNRAR başlığı hariç) arşiv yorumudur.
        var preface: [String] = []

        func flush() {
            defer { block.removeAll(keepingCapacity: true) }
            guard let name = block["Name"] else { return }
            let type = block["Type"] ?? "File"
            if type.hasPrefix("Service") { return }
            let isDir = type.hasPrefix("Directory")
            let isLink = type.lowercased().contains("link")
            let flags = (block["Flags"] ?? "").lowercased()
            let crc = block["CRC32"] ?? block["BLAKE2sp"]
            entries.append(ArchiveEntry(
                path: name,
                isDirectory: isDir,
                isSymlink: isLink,
                size: Int64(block["Size"] ?? "") ?? 0,
                packedSize: Int64(block["Packed size"] ?? ""),
                modified: block["mtime"].flatMap(parseDate),
                crc32: crc,
                attributes: block["Attributes"],
                isEncrypted: flags.contains("encrypted"),
                method: block["Compression"],
                hostOS: block["Host OS"]))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if !line.hasPrefix(" "), line.contains("Incorrect password") || line.contains("Enter password") {
                passwordProblem = true
                continue
            }

            if line.isEmpty {
                flush()
                if !sawArchiveLine { preface.append("") }
                continue
            }

            // "     Key: value" biçimi: anahtar boşluklarla sağa yaslı, değer ilk ": " sonrasıdır.
            if let sep = line.range(of: ": ") {
                let key = line[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
                if Self.knownKeys.contains(key) {
                    let value = String(line[sep.upperBound...])
                    if key == "Archive" {
                        sawArchiveLine = true
                        recognized = true
                    } else if key == "Details" {
                        let parts = value.components(separatedBy: ", ")
                        info.formatName = parts.first ?? ""
                        info.flags = Array(parts.dropFirst()).map { $0.trimmingCharacters(in: .whitespaces) }
                    } else if key == "Name" {
                        flush()
                        block["Name"] = value // sondaki boşluk adın parçası olabilir
                    } else if sawArchiveLine {
                        block[key] = value.trimmingCharacters(in: .whitespaces)
                    }
                    continue
                }
            }
            if !sawArchiveLine { preface.append(line) }
        }
        flush()

        // preface: ilk satırlar "UNRAR/RAR ... Copyright", "Registered to" ve deneme sürümü hatırlatmaları gibi
        // başlıklardır; RAR 7.x ayrıca yorumun önüne "Archive comment:" başlığı yazar. Bunlar yorumun parçası değildir.
        let commentLines = preface.filter { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return !l.hasPrefix("UNRAR ") && !l.hasPrefix("RAR ") && !l.hasPrefix("Registered to")
                && !l.hasPrefix("Trial version") && !l.hasPrefix("Evaluation copy")
                && l.lowercased() != "archive comment:"
                && !l.contains("rarreg.key") && l != "Operation not permitted"
        }
        let comment = commentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { info.comment = comment }

        return Result(entries: entries, info: info, passwordProblem: passwordProblem, recognizedArchive: recognized)
    }

    private static let knownKeys: Set<String> = [
        "Archive", "Details", "Volume", "Name", "Type", "Size", "Packed size", "Ratio", "mtime", "ctime",
        "atime", "Attributes", "CRC32", "BLAKE2sp", "Host OS", "Compression", "Flags", "Target",
        "Symlink", "Hardlink", "Redirection",
    ]
}

// MARK: - lsar -j (The Unarchiver) ayrıştırıcısı

/// `lsar -j` çıktısını (JSON) girdilere çevirir. `unrar`/`rar` yokken RAR'ı açmak için kullanılan yedek yol.
public enum UnarListParser {
    public struct Result: Sendable {
        public var entries: [ArchiveEntry]
        public var formatName: String
        /// `lsarError` değeri (yoksa nil): 15 = parola hatası, 11 = dosya açılamadı, 0 = arşiv tanınmadı.
        public var errorCode: Int?
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// JSON değilse nil.
    public static func parse(_ data: Data) -> Result? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let items = root["lsarContents"] as? [[String: Any]] ?? []
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(items.count)
        for e in items {
            guard var name = e["XADFileName"] as? String else { continue }
            let isDir = (e["XADIsDirectory"] as? Bool) ?? false
            while name.hasSuffix("/") { name.removeLast() }
            if name.isEmpty { continue }

            // Biçime özgü anahtarlar farklıdır (RAR5CRC32, ZipCRC32 …); sayısal "…CRC32" anahtarını ara.
            var crc: String?
            if !isDir, let key = e.keys.first(where: { $0.hasSuffix("CRC32") && e[$0] is NSNumber }),
               let n = e[key] as? NSNumber {
                crc = String(format: "%08X", n.uint32Value)
            }
            let hostOS = e.first(where: { $0.key.hasSuffix("OSName") })?.value as? String
            let modified = (e["XADLastModificationDate"] as? String).flatMap { dateFormatter.date(from: $0) }

            entries.append(ArchiveEntry(
                path: name,
                isDirectory: isDir,
                isSymlink: (e["XADIsLink"] as? Bool) ?? false,
                size: isDir ? 0 : ((e["XADFileSize"] as? NSNumber)?.int64Value ?? 0),
                packedSize: (e["XADCompressedSize"] as? NSNumber)?.int64Value,
                modified: modified,
                crc32: crc,
                isEncrypted: (e["XADIsEncrypted"] as? Bool) ?? false,
                method: e["XADCompressionName"] as? String,
                hostOS: hostOS,
                index: (e["XADIndex"] as? NSNumber)?.intValue))
        }
        return Result(entries: entries,
                      formatName: (root["lsarFormatName"] as? String) ?? "",
                      errorCode: (root["lsarError"] as? NSNumber)?.intValue)
    }
}

// MARK: - bsdtar -tvf ayrıştırıcısı

public enum TarListParser {
    // -rw-r--r--  0 501    0           3 Oct  9 10:20 ./kök.txt
    private static let regex = try! NSRegularExpression(
        pattern: #"^([-dlcbpsh])[rwxsStT-]{9}[@+.]?\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s(.*)$"#)

    private static let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                                 "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]

    public static func parse(_ text: String, now: Date = Date()) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let cal = Calendar(identifier: .gregorian)
        let currentYear = cal.component(.year, from: now)

        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }

            let kind = g(1)
            let size = Int64(g(4)) ?? 0
            var name = g(8)
            let isLink = kind == "l"
            if isLink, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            else if kind == "h", let arrow = name.range(of: " link to ") { name = String(name[..<arrow.lowerBound]) }

            var comps = DateComponents()
            comps.month = months[g(5)]
            comps.day = Int(g(6))
            let timeOrYear = g(7)
            if timeOrYear.contains(":") {
                let hm = timeOrYear.split(separator: ":")
                comps.hour = Int(hm[0]); comps.minute = Int(hm[1])
                comps.year = currentYear
            } else {
                comps.year = Int(timeOrYear)
            }
            var date = cal.date(from: comps)
            // ls benzeri biçim: saat gösteriliyorsa tarih son ~6 ay içindedir; gelecekteyse geçen yıl.
            if timeOrYear.contains(":"), let d = date, d.timeIntervalSince(now) > 86_400 {
                comps.year = currentYear - 1
                date = cal.date(from: comps)
            }

            var normalized = name
            while normalized.hasPrefix("./") { normalized.removeFirst(2) }
            let isDir = kind == "d" || normalized.hasSuffix("/")
            while normalized.hasSuffix("/") { normalized.removeLast() }
            if normalized.isEmpty || normalized == "." { continue } // kök "./" girdisi

            entries.append(ArchiveEntry(
                path: normalized,
                rawName: name,
                isDirectory: isDir,
                isSymlink: isLink,
                size: isDir ? 0 : size,
                modified: date,
                attributes: String(line.prefix(10))))
        }
        return entries
    }
}

// MARK: - İlerleme çıktısı ayrıştırıcısı

public enum ProgressEvent: Equatable, Sendable {
    /// İşlenmeye başlanan dosya (ad, araç çıktısındaki haliyle).
    case file(name: String)
    case percent(Int)
    case fileFinished(ok: Bool)
    /// Dosya satırı olmayan serbest metin (başlık, hata, özet...).
    case message(String)
}

/// rar/unrar ilerleme çıktısını (\n, \r ve \b ile ayrılmış parçalar) olaylara çevirir.
/// Parça sınırları okuma boyutlarıyla örtüşmeyebilir; bu yüzden tampon tutar.
public struct ProgressParser: Sendable {
    public enum Style: Sendable { case rar, bsdtar, unar }

    private var buffer = Data()
    private let style: Style

    public init(style: Style = .rar) { self.style = style }

    private static let verbs = ["Extracting", "Adding", "Creating", "Testing", "Deleting",
                                "Updating", "Freshening", "Moving", "Skipping", "Renaming",
                                "Copying", "Reconstructing", "Repairing"]
    private static let percentRegex = try! NSRegularExpression(pattern: #"^(\d{1,3})%$"#)

    public mutating func feed(_ data: Data) -> [ProgressEvent] {
        buffer.append(data)
        var events: [ProgressEvent] = []
        var tokenStart = buffer.startIndex
        var i = buffer.startIndex
        while i < buffer.endIndex {
            let b = buffer[i]
            if b == 0x0A || b == 0x0D || b == 0x08 {
                if i > tokenStart {
                    events += Self.interpret(buffer[tokenStart..<i], style: style)
                }
                tokenStart = buffer.index(after: i)
            }
            i = buffer.index(after: i)
        }
        buffer = Data(buffer[tokenStart...])
        return events
    }

    // "src/dosya.txt  (14 B)... OK." (çıkarma) veya "src/dosya.txt... OK." (lsar -t sınaması)
    private static let unarSizedRegex = try! NSRegularExpression(pattern: #"^(.*)  \(([^)]*)\)\.\.\.\s*(.*)$"#)
    private static let unarPlainRegex = try! NSRegularExpression(pattern: #"^(.+?)\.\.\. +(OK\.?|Failed.*|Unpacking failed.*)$"#)

    static func interpretUnar(_ token: String) -> [ProgressEvent] {
        let ns = token as NSString
        let full = NSRange(location: 0, length: ns.length)
        var name: String?, result = ""
        if let m = unarSizedRegex.firstMatch(in: token, range: full) {
            name = ns.substring(with: m.range(at: 1)); result = ns.substring(with: m.range(at: 3))
        } else if let m = unarPlainRegex.firstMatch(in: token, range: full) {
            name = ns.substring(with: m.range(at: 1)); result = ns.substring(with: m.range(at: 2))
        }
        guard let name else { return [.message(token)] }
        var events: [ProgressEvent] = [.file(name: name)]
        if result.hasPrefix("Failed") || result.hasPrefix("Unpacking failed") {
            events += [.fileFinished(ok: false), .message(token)]
        } else {
            events.append(.fileFinished(ok: true))
        }
        return events
    }

    /// Akış bittiğinde kalan son parçayı boşaltır.
    public mutating func finish() -> [ProgressEvent] {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty else { return [] }
        return Self.interpret(buffer[...], style: style)
    }

    static func interpret(_ bytes: Data.SubSequence, style: Style) -> [ProgressEvent] {
        let raw = String(decoding: bytes, as: UTF8.self)
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if token.isEmpty { return [] }

        if style == .unar { return interpretUnar(token) }

        if style == .bsdtar {
            // "a ./yol" (ekleme) veya "x ./yol" (çıkarma)
            if (token.hasPrefix("a ") || token.hasPrefix("x ")) && token.count > 2 {
                return [.file(name: String(token.dropFirst(2))), .fileFinished(ok: true)]
            }
            return [.message(token)]
        }

        let nsToken = token as NSString
        if let m = percentRegex.firstMatch(in: token, range: NSRange(location: 0, length: nsToken.length)),
           let p = Int(nsToken.substring(with: m.range(at: 1))) {
            return [.percent(min(p, 100))]
        }
        if token == "OK" { return [.fileFinished(ok: true)] }
        if token.hasPrefix("Failed") { return [.fileFinished(ok: false), .message(token)] }

        for verb in verbs where token.hasPrefix(verb + " ") {
            var rest = String(token.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            // "Extracting from x.rar", "Creating archive x.rar", "Deleting from x.rar" gibi başlıklar
            if rest.hasPrefix("from ") || rest.hasPrefix("archive ") || rest.hasPrefix("data recovery") {
                return [.message(token)]
            }
            var finished = false
            // Dizin satırları: "Creating    out/src      OK" (aynı parçada)
            if let okRange = rest.range(of: #"\s{2,}OK$"#, options: .regularExpression) {
                rest = String(rest[..<okRange.lowerBound])
                finished = true
            }
            var events: [ProgressEvent] = [.file(name: rest)]
            if finished { events.append(.fileFinished(ok: true)) }
            return events
        }
        return [.message(token)]
    }
}

/// İşlem sırasında ilerleme yüzdesini ve günlüğü iş parçacığı güvenli biçimde biriktirir.
public final class ProgressTracker: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var fraction: Double?
        public var currentFile: String
        public var newMessages: [String]
        public var filesDone: Int
    }

    private let lock = NSLock()
    private var parser: ProgressParser
    private let weights: [String: Int64]
    private let totalBytes: Int64
    private let stripPrefix: String
    private let flatten: Bool

    private var current = ""
    private var currentWeight: Int64 = 0
    private var currentPercent = 0
    /// İşlenmekte olan dosya ve o ana dek işlenen bayt (işletim sisteminden okunur; yüzde vermeyen bsdtar için).
    /// bsdtar dosya adını dosya BİTTİKTEN sonra yazdırdığından, hangi dosyanın sürdüğü açık dosya yolundan anlaşılır.
    private var activeKey: String?
    private var activeOffset: Int64 = 0
    /// Tamamlanan dosyalar: bitmiş bir dosyanın açık konumu (kapanmadan önce okunursa) yeniden sayılmasın.
    private var completedKeys = Set<String>()
    private var currentKey = ""
    /// Çubuk geri gitmez: rar sıkıştırılamayan veride yüzdeyi ikinci kez 0'dan başlatabilir.
    private var maxFraction: Double = 0
    private var doneBytes: Int64 = 0
    private var filesDone = 0
    private var pendingMessages: [String] = []

    /// - Parameters:
    ///   - weights: Dosya yolu → boyut (ilerleme ağırlığı).
    ///   - stripPrefix: Araç çıktısındaki adların başındaki ön ek (hedef klasör gibi).
    ///   - flatten: Yol olmadan çıkarılıyorsa yalnızca dosya adıyla eşleştir.
    public init(weights: [String: Int64] = [:], stripPrefix: String = "", flatten: Bool = false,
                style: ProgressParser.Style = .rar) {
        self.parser = ProgressParser(style: style)
        self.weights = weights
        self.totalBytes = weights.values.reduce(0, +)
        self.stripPrefix = stripPrefix
        self.flatten = flatten
    }

    public func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        for e in parser.feed(data) { apply(e) }
    }

    public func finish() {
        lock.lock(); defer { lock.unlock() }
        for e in parser.finish() { apply(e) }
    }

    /// Aracın açık dosyaları (göreli yol → konum). Ağırlığı bilinenlerin en ilerlemişi "sürmekte olan dosya" sayılır.
    public func setActive(candidates: [(key: String, offset: Int64)]) {
        lock.lock(); defer { lock.unlock() }
        let known = candidates.filter { weights[$0.key] != nil && !completedKeys.contains($0.key) }
        guard let best = known.max(by: { $0.offset < $1.offset }) else { return }
        activeKey = best.key
        activeOffset = max(0, best.offset)
    }

    private func key(for name: String) -> String {
        var n = name
        if !stripPrefix.isEmpty, n.hasPrefix(stripPrefix) { n = String(n.dropFirst(stripPrefix.count)) }
        while n.hasPrefix("./") { n.removeFirst(2) }
        if flatten, let slash = n.lastIndex(of: "/") { n = String(n[n.index(after: slash)...]) }
        return n
    }

    private func apply(_ e: ProgressEvent) {
        switch e {
        case .file(let name):
            current = name
            currentPercent = 0
            currentKey = key(for: name)
            currentWeight = weights[currentKey] ?? 0
        case .percent(let p):
            currentPercent = p
        case .fileFinished:
            doneBytes += currentWeight
            completedKeys.insert(currentKey)
            if activeKey == currentKey { activeKey = nil; activeOffset = 0 }   // bitti: artık "tamamlanan" bayt olarak sayılır
            filesDone += 1
            currentWeight = 0
            currentPercent = 0
        case .message(let m):
            pendingMessages.append(m)
        }
    }

    public func drain() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var fraction: Double?
        if totalBytes > 0 {
            let byPercent = Double(currentWeight) * Double(currentPercent) / 100
            let byOffset = activeKey.map { Double(min(activeOffset, weights[$0] ?? 0)) } ?? 0
            let partial = max(byPercent, byOffset)
            fraction = min(1, (Double(doneBytes) + partial) / Double(totalBytes))
            maxFraction = max(maxFraction, fraction ?? 0)
            fraction = maxFraction
        }
        let msgs = pendingMessages
        pendingMessages.removeAll()
        return Snapshot(fraction: fraction, currentFile: current, newMessages: msgs, filesDone: filesDone)
    }
}
