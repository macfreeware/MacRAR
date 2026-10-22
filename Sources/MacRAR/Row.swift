import SwiftUI
import UniformTypeIdentifiers
import MacRARCore

/// Tabloda gösterilen tek satır (klasör modunda gerçek dosya, arşiv modunda arşiv girdisi).
struct Row: Identifiable, Hashable {
    let id: String
    let name: String
    /// Arama sonuçlarında gösterilen üst klasör.
    let location: String
    let isDirectory: Bool
    let sizeValue: Int64
    let packedValue: Int64
    let modifiedValue: Date
    let hasDate: Bool
    let kind: String
    let crc: String
    let isEncrypted: Bool
    let isSymlink: Bool
    /// Arşiv modunda: arşivdeki girdi (sentezlenmiş klasörlerde nil).
    let entry: ArchiveEntry?
    /// Arşiv modunda: arşiv içindeki tam sanal yol.
    let archivePath: String
    /// Klasör modunda: gerçek dosya.
    let url: URL?
    let isArchiveFile: Bool

    static func == (l: Row, r: Row) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var sizeText: String { isDirectory ? "" : Format.bytes(sizeValue) }
    var packedText: String { isDirectory || packedValue <= 0 && sizeValue == 0 ? "" : Format.bytes(packedValue) }
    var modifiedText: String { hasDate ? Format.date(modifiedValue) : "" }

    // MARK: Oluşturucular

    init(entry e: ArchiveEntry) {
        id = e.rawName
        name = e.name
        location = e.parentPath
        isDirectory = e.isDirectory
        sizeValue = e.isDirectory ? 0 : e.size
        packedValue = e.packedSize ?? 0
        modifiedValue = e.modified ?? .distantPast
        hasDate = e.modified != nil
        kind = Format.kind(name: e.name, isDirectory: e.isDirectory, isSymlink: e.isSymlink)
        crc = e.isDirectory ? "" : (e.crc32 ?? "")
        isEncrypted = e.isEncrypted
        isSymlink = e.isSymlink
        entry = e
        archivePath = e.path
        url = nil
        isArchiveFile = false
    }

    init(folderItem f: FolderItem) {
        id = f.url.path
        name = f.url.lastPathComponent
        location = ""
        isDirectory = f.isDirectory
        sizeValue = f.isDirectory ? 0 : f.size
        packedValue = 0
        modifiedValue = f.modified ?? .distantPast
        hasDate = f.modified != nil
        kind = f.isPackage ? String(localized: "Uygulama / paket") : Format.kind(name: f.url.lastPathComponent, isDirectory: f.isDirectory, isSymlink: false)
        crc = ""
        isEncrypted = false
        isSymlink = false
        entry = nil
        archivePath = ""
        url = f.url
        isArchiveFile = !f.isDirectory && ArchiveTypes.isArchive(f.url)
    }
}

/// Klasör içeriğini okuyan arka plan işi için taşıma yapısı.
struct FolderItem: Sendable {
    let url: URL
    let isDirectory: Bool
    let isPackage: Bool
    let size: Int64
    let modified: Date?
}

enum FolderLoader {
    static func load(_ dir: URL, showHidden: Bool) throws -> [FolderItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return FolderItem(url: u,
                              isDirectory: v?.isDirectory ?? false,
                              isPackage: v?.isPackage ?? false,
                              size: Int64(v?.fileSize ?? 0),
                              modified: v?.contentModificationDate)
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func date(_ d: Date) -> String { dateFormatter.string(from: d) }

    private nonisolated(unsafe) static var kindCache: [String: String] = [:]

    static func kind(name: String, isDirectory: Bool, isSymlink: Bool) -> String {
        if isDirectory { return String(localized: "Klasör") }
        if isSymlink { return String(localized: "Sembolik bağlantı") }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return String(localized: "Dosya") }
        if let cached = kindCache[ext] { return cached }
        let desc = UTType(filenameExtension: ext)?.localizedDescription ?? String(localized: "\(ext.uppercased()) dosyası")
        kindCache[ext] = desc
        return desc
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Satır simgeleri (uzantıya göre önbelleklenir).
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for row: Row) -> NSImage {
        if row.isDirectory {
            if let url = row.url, url.pathExtension.lowercased() == "app" {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return cached("•folder") { NSWorkspace.shared.icon(for: .folder) }
        }
        let ext = (row.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return cached("•file") { NSWorkspace.shared.icon(for: .data) } }
        return cached(ext) {
            NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
    }

    static func archiveIcon() -> NSImage {
        cached("•archive") { NSWorkspace.shared.icon(for: UTType(filenameExtension: "rar") ?? .archive) }
    }

    private static func cached(_ key: String, make: () -> NSImage) -> NSImage {
        if let i = cache[key] { return i }
        let img = make()
        img.size = NSSize(width: 32, height: 32)
        cache[key] = img
        return img
    }
}
