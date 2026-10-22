import Foundation

/// İndirilmiş arşivlerdeki `com.apple.quarantine` özniteliğini çıkarılan dosyalara taşır.
/// rar/unrar/bsdtar bunu yapmaz; yapılmazsa arşivden çıkan bir uygulama/betik Gatekeeper
/// denetimine takılmadan çalışabilir (Apple'ın Arşiv Yardımcısı bu özniteliği taşır).
public enum Quarantine {
    static let attribute = "com.apple.quarantine"

    public static func value(of url: URL) -> Data? {
        let path = url.path
        let size = getxattr(path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
    }

    public static func apply(_ value: Data, to urls: [URL]) {
        for url in urls {
            _ = value.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        }
    }

    /// Kaynak arşivde karantina varsa `files` hepsine uygular.
    public static func propagate(from archive: URL, to files: [URL]) {
        guard let v = value(of: archive) else { return }
        apply(v, to: files)
    }
}
