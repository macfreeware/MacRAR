import Foundation

/// Arşiv dosyası uzantıları (yalnızca ad üzerinden; eklenti korumalı olduğundan dosya içeriğini okuyamaz).
public enum ArchiveTypes {
    public static let extensions: Set<String> = [
        "rar", "zip", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lz", "lzma", "zst",
        "cab", "iso", "cpio", "xar", "lha", "lzh", "cbr", "cbz", "jar", "war",
    ]

    public static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        // RAR eski çok parçalı adlandırma: .r00, .r01 ...
        if ext.count == 3, ext.hasPrefix("r"), ext.dropFirst().allSatisfy(\.isNumber) { return true }
        return false
    }
}

/// Finder sağ tık menüsünden (Finder Sync eklentisi) uygulamaya iletilen eylemler.
public enum FinderAction: String, CaseIterable, Sendable {
    case add                // Arşive Ekle… (Ekle penceresi)
    case compress           // ad.rar
    case compressStamped    // ad-<zaman damgası>.rar
    case open               // arşivi MacRAR'da aç
    case extractDialog      // Dosyaları Çıkar… (Çıkar penceresi)
    case extractHere        // arşivin klasörüne
    case extractFolder      // arşiv adıyla klasöre
    // Yeni eylemler HER ZAMAN sona eklenir: Finder eklentisi eylemi `allCases` içindeki sırasıyla (tag) iletir.
    case compressZip        // ad.zip (macOS'un yerleşik bsdtar'ı; rar gerekmez)
    case compressZipStamped // ad-<zaman damgası>.zip
}

public struct FinderMenuItem: Equatable, Sendable {
    public let action: FinderAction
    public let title: String
    public init(_ action: FinderAction, _ title: String) { self.action = action; self.title = title }
}

/// Menü içeriğinin (seçime göre) ve eklenti ↔ uygulama iletişiminin saf mantığı.
/// Hem uygulamada hem Finder eklentisinde derlenir; bu yüzden yalnızca Foundation kullanır.
public enum FinderIntegration {
    public static let scheme = "macrar"

    // MARK: Menü

    /// Dosya/klasör için arşiv adı tabanı. Eklenti dosya sistemine bakamaz; klasör ipucu olarak
    /// URL'nin sonundaki "/" kullanılır.
    public static func displayBase(_ url: URL) -> String {
        url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    /// Seçilen öğeler için sağ tık menüsü. Hepsi arşivse çıkarma, aksi halde sıkıştırma girdileri.
    /// `canCompressRAR` false ise (rar kurulu değil) RAR sıkıştırma girdileri gösterilmez; ZIP ve "Arşive Ekle…" kalır.
    /// `bundle`: menü metinlerinin çevirisi (eklenti, uygulamada seçilen dili `FinderState` üzerinden okur).
    public static func menuItems(for urls: [URL], canCompressRAR: Bool = true, bundle: Bundle = .main) -> [FinderMenuItem] {
        guard !urls.isEmpty else { return [] }
        let prefix = "MacRAR · "
        if urls.allSatisfy({ ArchiveTypes.isArchive($0) }) {
            var items = [
                FinderMenuItem(.open, prefix + String(localized: "Aç", bundle: bundle)),
                FinderMenuItem(.extractDialog, prefix + String(localized: "Dosyaları Çıkar…", bundle: bundle)),
                FinderMenuItem(.extractHere, prefix + String(localized: "Buraya Çıkar", bundle: bundle)),
            ]
            if urls.count == 1 {
                var base = urls[0].deletingPathExtension().lastPathComponent
                if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
                items.append(FinderMenuItem(.extractFolder, prefix + String(localized: "“\(base)/” klasörüne Çıkar", bundle: bundle)))
            } else {
                items.append(FinderMenuItem(.extractFolder, prefix + String(localized: "Her birini kendi klasörüne Çıkar", bundle: bundle)))
            }
            return items
        }
        func title(_ ext: String, _ multi: String) -> String {
            urls.count == 1 ? prefix + String(localized: "“\(displayBase(urls[0])).\(ext)” olarak Sıkıştır", bundle: bundle) : prefix + multi
        }
        var items = [FinderMenuItem(.add, prefix + String(localized: "Arşive Ekle…", bundle: bundle))]
        if canCompressRAR {
            items += [FinderMenuItem(.compress, title("rar", String(localized: "RAR’a Sıkıştır", bundle: bundle))),
                      FinderMenuItem(.compressStamped, prefix + String(localized: "Zaman Damgalı RAR’a Sıkıştır", bundle: bundle))]
        }
        items += [FinderMenuItem(.compressZip, title("zip", String(localized: "ZIP’e Sıkıştır", bundle: bundle))),
                  FinderMenuItem(.compressZipStamped, prefix + String(localized: "Zaman Damgalı ZIP’e Sıkıştır", bundle: bundle))]
        return items
    }

    // MARK: Eklenti → uygulama iletişimi (özel URL)

    /// `macrar://<eylem>?t=<anahtar>&p=<yol>&p=<yol>…`
    public static func commandURL(action: FinderAction, paths: [String], token: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = action.rawValue
        var items = [URLQueryItem(name: "t", value: token)]
        items += paths.map { URLQueryItem(name: "p", value: $0) }
        c.queryItems = items
        return c.url
    }

    /// URL'yi çözer. Anahtar uyuşmazsa nil döner: web sayfaları ya da başka uygulamalar uygulamayı
    /// bu şemayla tetikleyemesin diye anahtar derleme sırasında üretilir ve yalnızca uygulama ile
    /// eklentinin paketinde bulunur.
    public static func parse(_ url: URL, expectedToken: String?) -> (action: FinderAction, files: [URL])? {
        guard url.scheme == scheme,
              let expectedToken, !expectedToken.isEmpty,
              let host = url.host?.lowercased(),
              let action = FinderAction.allCases.first(where: { $0.rawValue.lowercased() == host }),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return nil }
        guard items.first(where: { $0.name == "t" })?.value == expectedToken else { return nil }
        var files: [URL] = []
        for item in items where item.name == "p" {
            guard let path = item.value, path.hasPrefix("/"), !path.contains("\0") else { return nil }
            files.append(URL(fileURLWithPath: (path as NSString).standardizingPath))
        }
        guard !files.isEmpty else { return nil }
        return (action, files)
    }
}
