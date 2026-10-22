import Foundation

/// Finder eklentisi ile uygulama arasındaki gizli anahtar: **her kurulumda (kullanıcı hesabında) ayrı**,
/// ilk açılışta rastgele üretilir ve yalnızca o kullanıcının dizininde, yalnızca sahibin okuyabildiği
/// izinle (0600) saklanır. Hiçbir sürümde sabit/ortak bir anahtar yoktur.
///
/// Anahtar, eklentiyi tetikleyen `macrar://` bağlantılarını doğrular: bir web sayfası anahtarı bilemez
/// (dosyayı okuyamaz), bu yüzden uygulamayı bu şemayla tetikleyemez.
///
/// Hem uygulamada hem (korumalı çalışan) Finder eklentisinde derlenir; yalnızca Foundation kullanır.
public enum FinderToken {
    public static let directoryName = "MacRAR"
    public static let fileName = "finder.token"
    /// Beklenen anahtar uzunluğu (32 bayt = 64 onaltılık karakter).
    public static let length = 64

    /// Gerçek ev dizini. Korumalı süreçlerde `homeDirectoryForCurrentUser` kapsayıcı dizinini döndürür;
    /// gerçek dizin için kullanıcı veritabanına bakılır.
    public static func realHome() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func directoryURL(home: URL = realHome()) -> URL {
        home.appendingPathComponent("Library/Application Support/\(directoryName)", isDirectory: true)
    }

    public static func fileURL(home: URL = realHome()) -> URL {
        directoryURL(home: home).appendingPathComponent(fileName)
    }

    /// Geçerli bir anahtar varsa döndürür (yoksa veya biçimi bozuksa nil). Eklenti bunu okur.
    public static func read(home: URL = realHome()) -> String? {
        guard let data = try? Data(contentsOf: fileURL(home: home)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValid(token) ? token : nil
    }

    public static func isValid(_ token: String) -> Bool {
        token.count == length && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Sistemin güvenli rastgele sayı üretecinden 32 bayt → 64 onaltılık karakter.
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    /// Geçerli anahtar yoksa üretip yazar (klasör 0700, dosya 0600); varsa dokunmaz ama izinleri onarır.
    /// Uygulama her açılışta çağırır. Güncellemelerde anahtar korunur; silinirse bir sonraki açılışta yenilenir.
    @discardableResult
    public static func ensureExists(home: URL = realHome()) throws -> String {
        let fm = FileManager.default
        let dir = directoryURL(home: home), file = fileURL(home: home)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        if let existing = read(home: home) {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return existing
        }
        let token = generate()
        try? fm.removeItem(at: file)
        guard fm.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }
}
