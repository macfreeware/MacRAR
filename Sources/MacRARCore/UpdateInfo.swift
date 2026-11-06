import Foundation

/// GitLab'daki son sürümün bilgileri (`/api/v4/projects/<yol>/releases/permalink/latest`).
public struct UpdateRelease: Sendable, Equatable {
    public let version: String
    /// Yayımlandığı gibi, iki dilli sürüm notları.
    public let notes: String
    public let page: URL
    /// Uygulamanın zip'i (sabit ad: `MacRAR.zip`); kendini güncellemeden eski sürümlerde yoktur.
    public let archive: URL?
    /// Zip'in SHA-256 özeti (`MacRAR.zip.sha256`).
    public let checksum: URL?

    public init(version: String, notes: String, page: URL, archive: URL?, checksum: URL?) {
        self.version = version
        self.notes = notes
        self.page = page
        self.archive = archive
        self.checksum = checksum
    }
}

/// GitLab sürüm yanıtının okunması ve güncellemenin saf yardımcıları (test edilir).
public enum UpdateInfo {
    public static let archiveName = "MacRAR.zip"
    public static let checksumName = "MacRAR.zip.sha256"
    public static let releasesPage = URL(string: "https://gitlab.com/freeware2/macrar/-/releases")!
    public static let finderExtensionPath = "Contents/PlugIns/MacRARFinder.appex"

    public static let latestReleaseURL = URL(string: "https://gitlab.com/api/v4/projects/freeware2%2Fmacrar/releases/permalink/latest")!

    /// Dosya ve sayfa bağlantıları yalnızca `https://gitlab.com` üzerinde olabilir.
    public static func isTrusted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "gitlab.com"
    }

    /// GitLab sürüm yanıtını çözer. Etiket "v1.2.3" ya da "1.2.3". `gitlab.com` dışındaki bağlantılar yok sayılır;
    /// `allowFileURLs` yalnızca deneme derlemesindeki yerel sahte sürümler içindir.
    public static func parse(_ data: Data, allowFileURLs: Bool = false) throws -> UpdateRelease {
        struct Payload: Decodable {
            let tag_name: String
            let description: String?
            let _links: Links?
            let assets: Assets?
            struct Links: Decodable { let `self`: String? }
            struct Assets: Decodable { let links: [Link]? }
            struct Link: Decodable { let name: String; let url: String; let direct_asset_url: String? }
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        func allowed(_ text: String?) -> URL? {
            guard let url = text.flatMap(URL.init(string:)), isTrusted(url) || (allowFileURLs && url.isFileURL) else { return nil }
            return url
        }
        func asset(_ name: String) -> URL? {
            guard let link = p.assets?.links?.first(where: { $0.name == name }) else { return nil }
            return allowed(link.direct_asset_url ?? link.url)
        }
        return UpdateRelease(version: version, notes: p.description ?? "",
                             page: allowed(p._links?.`self`) ?? releasesPage,
                             archive: asset(archiveName), checksum: asset(checksumName))
    }

    /// Noktalı sürümlerin sayısal karşılaştırması: 1.10 > 1.9, 1.2.1 > 1.2.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// `shasum -a 256` çıktısından özet: "abc…  MacRAR.zip" ya da yalnızca "abc…". Küçük harfe çevrilir.
    public static func parseChecksum(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hex = first.lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// Notların arayüz dilindeki "yenilikler" bölümü, düz metin olarak; böyle bir başlık yoksa notların tamamı.
    public static func whatsNew(in notes: String, turkish: Bool) -> String {
        let lines = notes.components(separatedBy: .newlines)
        let start = lines.firstIndex {
            $0.hasPrefix("#") && $0.localizedCaseInsensitiveContains(turkish ? "yenilikler" : "what's new")
        }
        guard let start else { return notes }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("#") || $0.hasPrefix("---") } ?? rest.endIndex
        return rest[..<end].joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uygulama kapanınca çalışan kabuk komutu: `$0` yeni uygulamanın yolu, `$1` Finder eklentisi etkinse "1".
    /// Eski eklenti süreci eski paketin dosyalarına bağlı kalır ve menü kaybolur; bu yüzden yeni paket sisteme tanıtılır
    /// ve eklenti yeniden başlatılır. Kullanıcı eklentiyi kapattıysa açılmaz.
    public static func relaunchScript(processID: Int32) -> String {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        return """
        while kill -0 \(processID) 2>/dev/null; do sleep 0.2; done
        \(lsregister) -f "$0"
        /usr/bin/pluginkit -a "$0/\(finderExtensionPath)"
        /System/Library/CoreServices/pbs -update
        if [ "$1" = "1" ]; then
          /usr/bin/pluginkit -e use -i \(AppRemoval.finderExtensionID)
          /usr/bin/killall MacRARFinder
        fi
        /usr/bin/open "$0"
        """
    }
}
