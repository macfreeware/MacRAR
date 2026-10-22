import Foundation

/// Uygulamanın Finder eklentisine bıraktığı durum bilgisi (`~/Library/Application Support/MacRAR/finder.state`).
///
/// Eklenti korumalı (sandbox) çalıştığından `rar`'ın kurulu olup olmadığını kendisi güvenle belirleyemez; uygulama araçları
/// her algıladığında sonucu buraya yazar, eklenti sağ tık menüsünü kurarken okur. Eklenti yalnızca okur
/// (bkz. FinderSync.entitlements). Hem uygulamada hem eklentide derlenir; yalnızca Foundation kullanır.
public enum FinderState {
    public static let fileName = "finder.state"

    public static func fileURL(home: URL = FinderToken.realHome()) -> URL {
        FinderToken.directoryURL(home: home).appendingPathComponent(fileName)
    }

    /// `rar`'ın (RAR oluşturabilen araç) varlığını ve uygulamada seçilen arayüz dilini (nil: sistem dili) yazar.
    /// Klasör yoksa (uygulama henüz ilk açılış hazırlığını yapmadı ya da testler) hiçbir şey oluşturmaz. Başarıyı döndürür.
    @discardableResult
    public static func writeCanCompressRAR(_ value: Bool, language: String? = nil, home: URL = FinderToken.realHome()) -> Bool {
        let dir = FinderToken.directoryURL(home: home)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let data = Data(("rar=\(value ? 1 : 0)\n" + (language.map { "lang=\($0)\n" } ?? "")).utf8)
        return (try? data.write(to: fileURL(home: home), options: .atomic)) != nil
    }

    /// nil: bilinmiyor (dosya yok/bozuk).
    public static func readCanCompressRAR(home: URL = FinderToken.realHome()) -> Bool? {
        guard let data = try? Data(contentsOf: fileURL(home: home)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "rar=1" { return true }
            if line.trimmingCharacters(in: .whitespaces) == "rar=0" { return false }
        }
        return nil
    }

    /// Uygulamada seçilen arayüz dili ("tr", "en"); sistem dili seçiliyse ya da bilinmiyorsa nil.
    public static func readLanguage(home: URL = FinderToken.realHome()) -> String? {
        guard let data = try? Data(contentsOf: fileURL(home: home)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("lang="), l.count > 5 { return String(l.dropFirst(5)) }
        }
        return nil
    }

    /// Eklentinin (uygulama çalışmasa da) bakabileceği bilinen `rar` konumları.
    public static func rarCandidatePaths(home: URL = FinderToken.realHome()) -> [String] {
        ["/opt/homebrew/bin/rar", "/usr/local/bin/rar", "/opt/local/bin/rar",
         FinderToken.directoryURL(home: home).appendingPathComponent("tools/rar/rar").path]
    }

    /// Menüde RAR sıkıştırma girdileri gösterilsin mi: uygulamanın yazdığı durum "var" diyorsa ya da bilinen bir
    /// konumda `rar` varsa (örn. uygulama kapalıyken Homebrew ile kurulduysa). Durum bilinmiyorsa gizlenir.
    public static func shouldOfferRARCompression(home: URL = FinderToken.realHome(),
                                                 exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        if readCanCompressRAR(home: home) == true { return true }
        return rarCandidatePaths(home: home).contains(where: exists)
    }
}
