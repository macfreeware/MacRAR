import Foundation

/// Komut satırı araçlarının sürümünü okur ("Hakkında" penceresi için).
public enum ToolProbe {
    /// "UNRAR 6.24 freeware …", "RAR 6.24 Copyright …", "bsdtar 3.7.4 - libarchive …" gibi çıktıdan sürüm numarasını alır.
    public static func parseVersion(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            let versionOnly = l.range(of: #"^v?\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil  // örn. unar: "v1.10.7"
            guard !l.isEmpty, versionOnly || l.lowercased().contains("rar") || l.lowercased().contains("bsdtar") else { continue }
            if let r = l.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) { return String(l[r]) }
        }
        return nil
    }

    /// Aracı çalıştırıp sürümünü döndürür. Bulunamazsa/okunamazsa nil.
    public static func version(of tool: URL, arguments: [String] = []) async -> String? {
        guard let result = try? await ProcessRunner.run(tool, arguments) else { return nil }
        return parseVersion(result.text)
    }
}

/// Paket bilgisinden sürüm metni üretir.
public struct VersionInfo: Equatable, Sendable {
    public var version: String?
    public var build: String?
    public var commit: String?

    public init(version: String?, build: String?, commit: String?) {
        self.version = version
        self.build = build
        self.commit = commit
    }

    public init(bundle: Bundle = .main) {
        self.init(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  commit: bundle.object(forInfoDictionaryKey: "MacRARCommit") as? String)
    }

    /// "Sürüm 1.0 (derleme 12 · 28071c6)" ya da paketsiz çalışırken "Geliştirme derlemesi".
    public var display: String {
        guard let version, !version.isEmpty else { return String(localized: "Geliştirme derlemesi") }
        var detail: [String] = []
        if let build, !build.isEmpty { detail.append(String(localized: "derleme \(build)")) }
        if let commit, !commit.isEmpty { detail.append(commit) }
        return String(localized: "Sürüm \(version)") + (detail.isEmpty ? "" : " (\(detail.joined(separator: " · ")))")
    }
}
