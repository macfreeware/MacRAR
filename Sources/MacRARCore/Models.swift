import Foundation

/// Arşiv işlemlerini yapan motor.
public enum ArchiveEngine: String, Sendable {
    /// `rar` / `unrar` komut satırı araçları.
    case rar
    /// `bsdtar` (libarchive): zip, 7z, tar.gz ... (salt okunur + sıfırdan oluşturma).
    case libarchive
}

public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    public var id: String { rawName }
    /// Normalize edilmiş yol: baştaki "./" ve sondaki "/" yok.
    public var path: String
    /// Aracın yazdığı haliyle ad. Araçlara geri verilirken bu kullanılır
    /// (macOS'ta NFC/NFD farkları yüzünden eşleşme için önemli).
    public var rawName: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var packedSize: Int64?
    public var modified: Date?
    public var crc32: String?
    public var attributes: String?
    public var isEncrypted: Bool
    public var method: String?
    public var hostOS: String?
    /// Arşivdeki sıra numarası (yalnızca `lsar` ile okunduğunda dolu); `unar -i` ile tam eşleşme için kullanılır.
    public var index: Int?

    public init(path: String, rawName: String? = nil, isDirectory: Bool, isSymlink: Bool = false,
                size: Int64, packedSize: Int64? = nil, modified: Date? = nil, crc32: String? = nil,
                attributes: String? = nil, isEncrypted: Bool = false, method: String? = nil,
                hostOS: String? = nil, index: Int? = nil) {
        self.path = path
        self.rawName = rawName ?? path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.crc32 = crc32
        self.attributes = attributes
        self.isEncrypted = isEncrypted
        self.method = method
        self.hostOS = hostOS
        self.index = index
    }

    public var name: String {
        if let slash = path.lastIndex(of: "/") { return String(path[path.index(after: slash)...]) }
        return path
    }

    public var parentPath: String {
        if let slash = path.lastIndex(of: "/") { return String(path[..<slash]) }
        return ""
    }
}

public struct ArchiveInfo: Sendable, Equatable {
    public var formatName: String = ""
    public var flags: [String] = []
    public var comment: String?

    public init(formatName: String = "", flags: [String] = [], comment: String? = nil) {
        self.formatName = formatName
        self.flags = flags
        self.comment = comment
    }

    private func has(_ word: String) -> Bool { flags.contains { $0.lowercased().contains(word) } }
    public var hasEncryptedHeaders: Bool { has("encrypted headers") }
    public var isSolid: Bool { has("solid") }
    public var isVolume: Bool { has("volume") }
    public var hasRecoveryRecord: Bool { has("recovery") }
    public var isLocked: Bool { flags.contains { $0.lowercased() == "lock" || $0.lowercased() == "locked" } }
}

public struct ArchiveListing: Sendable {
    public var entries: [ArchiveEntry]
    public var info: ArchiveInfo
    public var engine: ArchiveEngine

    public init(entries: [ArchiveEntry], info: ArchiveInfo, engine: ArchiveEngine) {
        self.entries = entries
        self.info = info
        self.engine = engine
    }

    public var fileCount: Int { entries.lazy.filter { !$0.isDirectory }.count }
    public var folderCount: Int { entries.lazy.filter { $0.isDirectory }.count }
    public var totalSize: Int64 { entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) } }
    public var totalPacked: Int64 { entries.reduce(0) { $0 + ($1.packedSize ?? 0) } }
    public var hasEncryptedFiles: Bool { entries.contains { $0.isEncrypted } }
}

// MARK: - Seçenekler

public enum OverwriteMode: String, CaseIterable, Sendable {
    case overwrite, skip, rename
}

public struct ExtractOptions: Sendable {
    public var destination: URL
    public var overwrite: OverwriteMode = .overwrite
    /// false ise dosyalar klasör yapısı olmadan doğrudan hedefe çıkarılır (sadece RAR).
    public var keepPaths: Bool = true
    public var keepBroken: Bool = false

    public init(destination: URL, overwrite: OverwriteMode = .overwrite, keepPaths: Bool = true, keepBroken: Bool = false) {
        self.destination = destination
        self.overwrite = overwrite
        self.keepPaths = keepPaths
        self.keepBroken = keepBroken
    }
}

public enum CompressionMethod: Int, CaseIterable, Sendable {
    case store = 0, fastest, fast, normal, good, best
}

public enum ArchiveFormat: String, CaseIterable, Sendable, Identifiable {
    case rar5, rar4, zip, sevenZip, tarGz, tarBz2, tarXz

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .rar5, .rar4: return "rar"
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        }
    }

    public var isRAR: Bool { self == .rar5 || self == .rar4 }
    public var supportsPassword: Bool { self == .rar5 || self == .rar4 || self == .zip }
}

public enum UpdateMode: String, CaseIterable, Sendable {
    /// Ekle ve değiştir
    case add
    /// Yalnızca yeni/değişenleri ekle
    case update
}

public struct CompressOptions: Sendable {
    public var archive: URL
    public var sources: [URL]
    public var format: ArchiveFormat = .rar5
    public var method: CompressionMethod = .normal
    /// RAR sözlük boyutu, örn. "32m". nil = otomatik.
    public var dictionary: String?
    public var solid: Bool = false
    public var password: String?
    public var encryptNames: Bool = false
    /// Kurtarma kaydı yüzdesi; 0 = yok.
    public var recoveryPercent: Int = 0
    public var testAfter: Bool = false
    public var deleteAfter: Bool = false
    public var lock: Bool = false
    /// Parça boyutu, örn. "100m". nil = tek dosya.
    public var volumeSize: String?
    public var updateMode: UpdateMode = .add
    public var keepSymlinks: Bool = true
    public var comment: String?
    /// Arşiv içinde dosyaların ekleneceği klasör (mevcut arşivin bir alt klasöründeyken).
    public var pathInArchive: String = ""
    /// true ise `archive` zaten var olan bir ZIP'tir: dosyalar ona eklenir (aynı adlılar değişir). false ise ZIP baştan yazılır.
    /// (RAR her zaman mevcut arşive ekler; TAR/7Z baştan yazılır.)
    public var appendToExisting: Bool = false

    public init(archive: URL, sources: [URL]) {
        self.archive = archive
        self.sources = sources
    }
}

// MARK: - Hatalar

public enum ArchiveError: LocalizedError, Sendable {
    case toolMissing(String)
    case passwordRequired
    case wrongPassword
    case unsupported(String)
    case failed(exitCode: Int32, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let tool):
            return String(localized: "“\(tool)” komut satırı aracı bulunamadı. Ayarlar’dan yolunu belirtin veya kurun. \(ToolGuidance.oneLiner)")
        case .passwordRequired:
            return String(localized: "Bu arşiv parola ile korunuyor.")
        case .wrongPassword:
            return String(localized: "Parola hatalı.")
        case .unsupported(let what):
            return what
        case .failed(let code, let message):
            let meaning = ArchiveError.describe(exitCode: code)
            if message.isEmpty { return meaning }
            return "\(meaning)\n\n\(message)"
        case .cancelled:
            return String(localized: "İşlem iptal edildi.")
        }
    }

    static func describe(exitCode: Int32) -> String {
        switch exitCode {
        case 1: return String(localized: "Uyarı: işlem tamamlandı ancak kritik olmayan bir sorun oluştu.")
        case 2: return String(localized: "Kritik hata.")
        case 3: return String(localized: "CRC hatası: arşiv bozuk veya parola yanlış.")
        case 4: return String(localized: "Arşiv kilitli; değiştirilemez.")
        case 5: return String(localized: "Diske yazma hatası (disk dolu veya izin yok).")
        case 6: return String(localized: "Dosya açılamadı.")
        case 7: return String(localized: "Komut satırı parametre hatası.")
        case 8: return String(localized: "Yetersiz bellek.")
        case 9: return String(localized: "Dosya oluşturulamadı.")
        case 10: return String(localized: "Belirtilen ada uyan dosya yok.")
        case 11: return String(localized: "Parola hatalı.")
        case 255: return String(localized: "İşlem kullanıcı tarafından durduruldu.")
        default: return String(localized: "İşlem başarısız oldu (çıkış kodu \(exitCode)).")
        }
    }
}

/// Başarıyla biten bir işlemin özeti.
public struct OperationReport: Sendable {
    public var warnings: [String] = []
    public var outputFiles: [URL] = []
    public init(warnings: [String] = [], outputFiles: [URL] = []) {
        self.warnings = warnings
        self.outputFiles = outputFiles
    }
}
