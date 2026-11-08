import Foundation

/// Arşivin içindeki bir Mac uygulaması (`X.app` paketi). Paket aslında bir klasördür; arşiv listesinde klasör gibi görünür.
public struct ArchivedApp: Hashable, Sendable {
    /// Arşiv içindeki yol: "X.app" ya da tek üst klasörlü düzende "X/X.app".
    public let path: String

    public init(path: String) { self.path = path }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var name: String { (fileName as NSString).deletingPathExtension }
    public var plistPath: String { path + "/Contents/Info.plist" }
    public func resourcePath(_ file: String) -> String { path + "/Contents/Resources/" + file }
}

public enum ArchivedApps {
    /// Arşiv listesinden uygulamaları bulur: `X.app/Contents/Info.plist` ve `X.app/Contents/MacOS/` içinde bir dosya gerekir,
    /// bu yüzden adı `.app` ile biten sıradan klasörler sayılmaz. Uygulama kökte ya da tek üst klasörde olabilir;
    /// uygulamanın içindeki yardımcı uygulamalar ve macOS'un `__MACOSX` / `._*` kayıtları sayılmaz.
    public static func find(in entries: [ArchiveEntry]) -> [ArchivedApp] {
        var plists = Set<String>()
        var executables = Set<String>()
        for entry in entries where !entry.isDirectory && !isMetadata(entry.path) {
            let parts = entry.path.split(separator: "/").map(String.init)
            guard let bundle = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") && $0.count > 4 }), bundle <= 1,
                  parts.count > bundle + 2, parts[bundle + 1] == "Contents" else { continue }
            let root = parts[...bundle].joined(separator: "/")
            if parts.count == bundle + 3, parts[bundle + 2] == "Info.plist" { plists.insert(root) }
            if parts.count == bundle + 4, parts[bundle + 2] == "MacOS" { executables.insert(root) }
        }
        return plists.intersection(executables).sorted().map(ArchivedApp.init)
    }

    private static func isMetadata(_ path: String) -> Bool {
        path.hasPrefix("__MACOSX/") || path.split(separator: "/").contains { $0.hasPrefix("._") }
    }
}

/// Uygulamanın `Info.plist` dosyasından okunanlar.
public struct AppBundleInfo: Equatable, Sendable {
    public let name: String?
    public let version: String?
    public let identifier: String?
    public let iconFile: String?

    /// Simge dosyasının adı; `CFBundleIconFile` uzantısız da yazılabilir.
    public var iconFileName: String? {
        guard let iconFile, !iconFile.isEmpty else { return nil }
        return (iconFile as NSString).pathExtension.isEmpty ? iconFile + ".icns" : iconFile
    }

    public init?(plist data: Data) {
        guard let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        name = d["CFBundleDisplayName"] as? String ?? d["CFBundleName"] as? String
        version = d["CFBundleShortVersionString"] as? String
        identifier = d["CFBundleIdentifier"] as? String
        iconFile = d["CFBundleIconFile"] as? String
    }
}

/// Arşivden çıkarılmış bir uygulamanın denetimi ve yerine konması. Karantina işareti korunur: internetten gelen uygulamayı
/// Gatekeeper yine denetler.
public enum AppInstaller {
    public enum Signature: Equatable, Sendable { case valid, unsigned }

    public struct Inspected: Sendable {
        public let url: URL
        public let info: AppBundleInfo
        public let signature: Signature
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notAnApp
        case unsafeLink(String)
        case brokenSignature
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notAnApp: String(localized: "Arşivdeki öğe geçerli bir uygulama değil.")
            case .unsafeLink(let path): String(localized: "Uygulama, paketinin dışını gösteren bir bağlantı içeriyor: \(path)")
            case .brokenSignature: String(localized: "Uygulamanın imzası bozuk; dosyalar değiştirilmiş olabilir.")
            case .failed(let message): String(localized: "Uygulama yerine konamadı: \(message)")
            }
        }
    }

    /// Sistemle etkileşen adımlar (testlerde değiştirilir).
    public struct Environment: Sendable {
        public var moveToTrash: @Sendable (URL) throws -> Void
        public var runPrivileged: @Sendable (String) async throws -> Void

        public static var live: Environment {
            Environment(moveToTrash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                        runPrivileged: { try await AppRemoval.liveRunPrivileged($0) })
        }
    }

    /// Paket yapısını, bağlantıları ve imzayı denetler. İmzasız uygulama kabul edilir (çağıran uyarır), bozuk imza edilmez.
    public static func inspect(_ app: URL) async throws -> Inspected {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = AppBundleInfo(plist: data) else { throw Failure.notAnApp }
        if let link = unsafeLink(in: app) { throw Failure.unsafeLink(link) }
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path])
        if result.exitCode == 0 { return Inspected(url: app, info: info, signature: .valid) }
        // İmzalı bir paketin ana dosyası değiştirilirse codesign da "imzasız" der; imza klasörü bunu ayırır.
        let sealed = FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_CodeSignature").path)
        guard result.text.contains("not signed at all"), !sealed else { throw Failure.brokenSignature }
        return Inspected(url: app, info: info, signature: .unsigned)
    }

    /// Paketin dışını gösteren ilk sembolik bağlantının paket içindeki yolu; yoksa nil.
    public static func unsafeLink(in app: URL) -> String? {
        let fm = FileManager.default
        guard let items = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return nil }
        for case let item as URL in items {
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                  let target = try? fm.destinationOfSymbolicLink(atPath: item.path) else { continue }
            if target.hasPrefix("/") || !staysInside(depth: items.level - 1, target: target) {
                return item.pathComponents.suffix(items.level).joined(separator: "/")
            }
        }
        return nil
    }

    private static func staysInside(depth start: Int, target: String) -> Bool {
        var depth = start
        for part in target.split(separator: "/") where part != "." {
            depth += part == ".." ? -1 : 1
            if depth < 0 { return false }
        }
        return true
    }

    /// Arşivin karantina işaretini uygulamadaki her öğeye (paketin kendisi dahil) taşır.
    public static func applyQuarantine(from archive: URL, to app: URL) {
        guard let value = Quarantine.value(of: archive) else { return }
        var urls = [app]
        if let items = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let item as URL in items { urls.append(item) }
        }
        Quarantine.apply(value, to: urls)
    }

    /// `folder` içinde boş bir ad: "X.app", doluysa "X 2.app", "X 3.app"…
    public static func uniqueDestination(for fileName: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).\(ext)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Yönetici yetkisiyle: varsa eskisini kullanıcının Çöp Sepeti'ne taşı, yenisini koy, sahipliği kullanıcıya ver.
    public static func privilegedCommand(app: URL, destination: URL, trash: URL?, userID: UInt32) -> String {
        var steps: [String] = []
        if let trash { steps.append("/bin/mv \(AppRemoval.shellQuote(destination.path)) \(AppRemoval.shellQuote(trash.path))") }
        steps.append("/bin/mv \(AppRemoval.shellQuote(app.path)) \(AppRemoval.shellQuote(destination.path))")
        steps.append("/usr/sbin/chown -R \(userID) \(AppRemoval.shellQuote(destination.path))")
        return steps.joined(separator: " && ")
    }

    /// Uygulamayı `destination`'a koyar; orada bir kopya varsa önce Çöp Sepeti'ne gider. Yazma izni yoksa yönetici parolası sorulur.
    /// Kullanıcı parola penceresini iptal ederse `CancellationError` atılır ve hiçbir şey değişmez.
    public static func install(_ app: URL, at destination: URL, environment env: Environment = .live) async throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: destination.path)
        let canWrite = fm.isWritableFile(atPath: destination.deletingLastPathComponent().path)
            && (!exists || fm.isWritableFile(atPath: destination.path))
        do {
            if canWrite {
                if exists { try env.moveToTrash(destination) }
                try fm.moveItem(at: app, to: destination)
            } else {
                let trash = exists ? uniqueDestination(for: destination.lastPathComponent, in: fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)) : nil
                try await env.runPrivileged(privilegedCommand(app: app, destination: destination, trash: trash, userID: getuid()))
            }
        } catch AppRemoval.RemovalError.cancelled {
            throw CancellationError()
        } catch AppRemoval.RemovalError.failed(let message) {
            throw Failure.failed(message)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }
}
