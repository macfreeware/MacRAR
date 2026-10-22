import Foundation

/// Kullanılan komut satırı araçlarının yolları.
public struct ToolPaths: Sendable, Equatable {
    public var rar: URL?
    public var unrar: URL?
    public var bsdtar: URL?
    /// The Unarchiver komut satırı araçları (LGPL, ücretsiz): RAR'ı yalnızca AÇMAK için alternatif.
    public var unar: URL?
    public var lsar: URL?

    public init(rar: URL? = nil, unrar: URL? = nil, bsdtar: URL? = nil, unar: URL? = nil, lsar: URL? = nil) {
        self.rar = rar
        self.unrar = unrar
        self.bsdtar = bsdtar
        self.unar = unar
        self.lsar = lsar
    }

    /// RAR arşivlerini okumak için kullanılacak RARLAB aracı (önce ücretsiz unrar).
    public var rarReader: URL? { unrar ?? rar }
    /// `unrar`/`rar` yokken RAR'ı açmak için kullanılabilecek `unar` + `lsar` çifti.
    public var canReadRARWithUnar: Bool { unar != nil && lsar != nil }
    /// RARLAB aracı kullanılacaksa true; yalnızca `unar` varsa false (salt okunur yedek yol).
    public var usesUnarForRAR: Bool { rarReader == nil && canReadRARWithUnar }
    public var canReadRAR: Bool { rarReader != nil || canReadRARWithUnar }
    public var canWriteRAR: Bool { rar != nil }

    /// GUI uygulamalarının PATH'i çok kısıtlıdır; bu yüzden bilinen dizinlere de bakılır.
    public static let searchDirectories: [String] = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        "/opt/local/bin", "/Applications/WinRAR.app/Contents/MacOS",
        // Kurulum Yardımcısı'nın RARLAB'dan indirip kurduğu rar/unrar (yönetici parolası gerektirmez); sistem yolları önceliklidir.
        RARInstaller.installDirectory.path,
    ] + (RARInstaller.bundledUnrarDirectory.map { [$0.path] } ?? [])

    public static func find(_ name: String, override: String? = nil) -> URL? {
        let fm = FileManager.default
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        var dirs = searchDirectories
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    public static func detect(rarOverride: String? = nil, unrarOverride: String? = nil,
                              bsdtarOverride: String? = nil) -> ToolPaths {
        ToolPaths(rar: find("rar", override: rarOverride),
                  unrar: find("unrar", override: unrarOverride),
                  bsdtar: find("bsdtar", override: bsdtarOverride),
                  unar: find("unar"), lsar: find("lsar"))
    }
}
