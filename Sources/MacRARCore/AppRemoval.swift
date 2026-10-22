import Foundation

/// "Yardım ▸ MacRAR'ı Kaldır…": uygulamayı ve (isteğe bağlı) kullanıcı verilerini sistemden temizler.
/// `scripts/uninstall.sh` ile aynı işi uygulamanın içinden yapar.
///
/// Sıra önemlidir: yönetici gerektiren adım (uygulamayı silme + kurulum kaydı) EN ÖNCE çalışır; kullanıcı parola
/// penceresini iptal ederse hiçbir şey değişmemiş olur.
public enum AppRemoval {
    public static let appName = "MacRAR.app"
    public static let bundleID = "local.macrar.app"
    public static let finderExtensionID = "local.macrar.app.FinderSync"
    public static let receiptID = "local.macrar.pkg"
    public static let vaultService = "local.macrar.password-manager"

    public struct Options: Equatable, Sendable {
        /// Ayarlar, Finder gizli anahtarı ve indirilen araçlar (`~/Library/Application Support/MacRAR`).
        public var removeUserData: Bool
        /// Anahtar Zinciri'ndeki kayıtlı parolalar (geri alınamaz).
        public var removePasswords: Bool
        public init(removeUserData: Bool = true, removePasswords: Bool = false) {
            self.removeUserData = removeUserData
            self.removePasswords = removePasswords
        }
    }

    public struct Report: Equatable, Sendable {
        /// Uygulama paketi silindi mi? (Uygulamalar klasörü dışından çalışan geliştirme kopyası silinmez.)
        public var appRemoved: Bool
        public var appPath: String
        public var userDataRemoved: Bool
        public var passwordsRemoved: Bool
    }

    public enum RemovalError: Error, LocalizedError, Equatable {
        case cancelled
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .cancelled: String(localized: "Kaldırma iptal edildi; hiçbir şey silinmedi.")
            case .failed(let m): String(localized: "Kaldırılamadı: \(m)")
            }
        }
    }

    /// Sistemle etkileşen adımlar (testlerde değiştirilir).
    public struct Environment: Sendable {
        public var appParents: [URL]
        public var supportDirectory: URL
        public var clearDefaults: @Sendable () -> Void
        public var receiptExists: @Sendable () async -> Bool
        public var runPrivileged: @Sendable (String) async throws -> Void
        public var runTool: @Sendable (String, [String]) async -> Int32
        public var scheduleFinalCleanup: @Sendable (_ removePreferencesFile: Bool) -> Void

        public static var live: Environment {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Environment(
                appParents: [URL(fileURLWithPath: "/Applications", isDirectory: true),
                             home.appendingPathComponent("Applications", isDirectory: true)],
                supportDirectory: home.appendingPathComponent("Library/Application Support/MacRAR", isDirectory: true),
                clearDefaults: { UserDefaults.standard.removePersistentDomain(forName: AppRemoval.bundleID) },
                receiptExists: { await AppRemoval.liveRun("/usr/sbin/pkgutil", ["--pkg-info", AppRemoval.receiptID]) == 0 },
                runPrivileged: { command in try await AppRemoval.liveRunPrivileged(command) },
                runTool: { path, args in await AppRemoval.liveRun(path, args) },
                scheduleFinalCleanup: { AppRemoval.liveScheduleFinalCleanup(removePreferencesFile: $0) })
        }
    }

    // MARK: Saf yardımcılar (test edilir)

    /// Yalnızca Uygulamalar klasöründeki (veya ~/Applications) "MacRAR.app" silinebilir; başka yerden çalışan kopya
    /// (örn. geliştirme klasörü) için nil döner.
    public static func removableApp(bundleURL: URL, parents: [URL]) -> URL? {
        let url = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard url.lastPathComponent == appName else { return nil }
        let parent = url.deletingLastPathComponent()
        return parents.contains { $0.standardizedFileURL.resolvingSymlinksInPath() == parent } ? url : nil
    }

    /// Tek tırnaklı kabuk dizgesi.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript çift tırnaklı dizge içeriği.
    public static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Yönetici yetkisiyle çalışacak komut: uygulamayı sil, (varsa) kurulum kaydını unut.
    public static func privilegedCommand(appPath: String, forgetReceipt: Bool) -> String {
        var command = "/bin/rm -rf \(shellQuote(appPath))"
        if forgetReceipt { command += " ; /usr/sbin/pkgutil --forget \(receiptID) >/dev/null 2>&1 ; true" }
        return command
    }

    // MARK: Kaldırma

    public static func remove(bundleURL: URL = Bundle.main.bundleURL,
                              options: Options,
                              environment env: Environment = .live,
                              progress: @Sendable (String) -> Void = { _ in }) async throws -> Report {
        let fm = FileManager.default
        let app = removableApp(bundleURL: bundleURL, parents: env.appParents)
        var appRemoved = false

        // 1) Uygulama + kurulum kaydı (yönetici gerekebilir). En önce: iptal edilirse hiçbir şey değişmez.
        if let app {
            progress(String(localized: "Uygulama siliniyor…"))
            let receipt = await env.receiptExists()
            if receipt || !fm.isDeletableFile(atPath: app.path) {
                try await env.runPrivileged(privilegedCommand(appPath: app.path, forgetReceipt: receipt))
            } else {
                do { try fm.removeItem(at: app) } catch { throw RemovalError.failed(error.localizedDescription) }
            }
            appRemoved = !fm.fileExists(atPath: app.path)
            if !appRemoved { throw RemovalError.failed(String(localized: "\(app.path) silinemedi.")) }
        }

        // 2) Finder eklentisi ve sistem kayıtları (hataları önemsiz: uygulama zaten gitmiş olabilir)
        progress(String(localized: "Finder eklentisi kaldırılıyor…"))
        _ = await env.runTool("/usr/bin/pluginkit", ["-e", "ignore", "-i", finderExtensionID])
        if let app {
            _ = await env.runTool("/usr/bin/pluginkit", ["-r", app.appendingPathComponent("Contents/PlugIns/MacRARFinder.appex").path])
            _ = await env.runTool(lsregisterPath, ["-u", app.path])
        }

        // 3) Kayıtlı parolalar
        var passwordsRemoved = false
        if options.removePasswords {
            progress(String(localized: "Kayıtlı parolalar siliniyor…"))
            passwordsRemoved = await env.runTool("/usr/bin/security", ["delete-generic-password", "-s", vaultService]) == 0
        }

        // 4) Ayarlar, gizli anahtar, indirilen araçlar
        var dataRemoved = false
        if options.removeUserData {
            progress(String(localized: "Ayarlar ve araçlar siliniyor…"))
            env.clearDefaults()
            if fm.fileExists(atPath: env.supportDirectory.path) {
                do { try fm.removeItem(at: env.supportDirectory); dataRemoved = true }
                catch { throw RemovalError.failed(error.localizedDescription) }
            } else {
                dataRemoved = true
            }
        }

        // 5) Uygulama kapandıktan sonra: tercih dosyasını temizle, Finder'ı yeniden başlat (menü kaybolsun).
        env.scheduleFinalCleanup(options.removeUserData)
        return Report(appRemoved: appRemoved, appPath: app?.path ?? bundleURL.path,
                      userDataRemoved: dataRemoved, passwordsRemoved: passwordsRemoved)
    }

    // MARK: Gerçek sistem işlemleri

    static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static func liveRun(_ path: String, _ args: [String]) async -> Int32 {
        guard let r = try? await ProcessRunner.run(URL(fileURLWithPath: path), args) else { return -1 }
        return r.exitCode
    }

    /// macOS'un standart yönetici parolası penceresi ile çalıştırır (`do shell script … with administrator privileges`).
    static func liveRunPrivileged(_ command: String) async throws {
        let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
        let r: ProcessResult
        do { r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script]) }
        catch { throw RemovalError.failed(error.localizedDescription) }
        if r.exitCode == 0 { return }
        if r.text.contains("-128") || r.text.localizedCaseInsensitiveContains("cancel") || r.text.contains("iptal") {
            throw RemovalError.cancelled
        }
        throw RemovalError.failed(r.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Uygulama kapandıktan sonra çalışan ayrı bir kabuk: önbellekteki tercih dosyasını siler, Finder'ı yeniden başlatır.
    static func liveScheduleFinalCleanup(removePreferencesFile: Bool) {
        var script = "sleep 2;"
        if removePreferencesFile {
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(bundleID).plist").path
            script += " /bin/rm -f \(shellQuote(plist)); /usr/bin/killall cfprefsd 2>/dev/null;"
        }
        script += " /usr/bin/killall Finder 2>/dev/null"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
