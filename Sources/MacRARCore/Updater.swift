import Foundation
import CryptoKit

/// Bir sürümü çalışan uygulamanın üzerine kurar: `MacRAR.zip` indirilir, `MacRAR.zip.sha256` ile karşılaştırılır,
/// içindeki uygulama denetlenir ve yerine konur. MacRAR Apple onaylı olmadığı için imza denetimi yalnızca paketin bozulmadığını
/// gösterir, yayıncıyı doğrulamaz. Ana iş parçacığı dışında çalışır, böylece hiç pencere açmadan denenebilir.
public enum Updater {
    public enum Failure: Error, LocalizedError, Equatable {
        case missingFiles
        case http(Int)
        case unreadableChecksum
        case checksumMismatch
        case unpackFailed
        case wrongApp
        case badSignature
        case notWritable(folder: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .missingFiles: String(localized: "Sürümde \(UpdateInfo.archiveName) ya da özet dosyası yok.")
            case .http(let code): String(localized: "GitLab yanıtı: HTTP \(code)")
            case .unreadableChecksum: String(localized: "Özet dosyası okunamadı.")
            case .checksumMismatch: String(localized: "İndirilen dosyanın özeti tutmuyor; dosya bozuk ya da değiştirilmiş olabilir.")
            case .unpackFailed: String(localized: "Arşiv açılamadı.")
            case .wrongApp: String(localized: "Arşivdeki uygulama beklenen MacRAR sürümü değil.")
            case .badSignature: String(localized: "Uygulamanın imzası doğrulanamadı.")
            case .notWritable(let folder, let reason): String(localized: "“\(folder)” klasörüne yazılamadı: \(reason)")
            }
        }
    }

    /// Denetlenmiş, kurulmaya hazır uygulama.
    public struct Prepared: Sendable {
        public let app: URL
        let work: URL
        let base: URL

        /// Geçici dosyaları siler.
        public func discard() {
            let fm = FileManager.default
            try? fm.removeItem(at: work)
            if base != fm.temporaryDirectory { try? fm.removeItem(at: base) }
        }
    }

    /// Uygulama bu kullanıcının yazamadığı bir yerdeyse false: başka kullanıcının kurduğu kopya, standart hesap,
    /// salt okunur ya da yer değiştirilmiş (translocated) kopya. Güncelleme o zaman indirme sayfası olarak önerilir.
    public static func canReplaceApp(at app: URL) -> Bool {
        let fm = FileManager.default
        return app.pathExtension == "app" && fm.isWritableFile(atPath: app.path)
            && fm.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Son sürümü sorar. İsteğe bu Mac hakkında hiçbir bilgi eklenmez.
    public static func fetchLatest(from url: URL = testURL ?? UpdateInfo.latestReleaseURL) async throws -> UpdateRelease {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(response)
        return try UpdateInfo.parse(data, allowFileURLs: testURL != nil)
    }

    /// İndirir, özeti doğrular, açar ve içindeki uygulamayı denetler. Çalışan uygulamaya henüz dokunmaz.
    /// Geçici klasör uygulamanın yanındadır: değiştirme kopyalama değil, aynı birimde yeniden adlandırma olur.
    public static func prepare(_ release: UpdateRelease, replacing current: URL, bundleID: String) async throws -> Prepared {
        guard let archive = release.archive, let checksum = release.checksum else { throw Failure.missingFiles }
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: checksum)
        try requireSuccess(checksumResponse)
        guard let expected = UpdateInfo.parseChecksum(String(decoding: checksumData, as: UTF8.self)) else {
            throw Failure.unreadableChecksum
        }
        let (downloaded, response) = try await URLSession.shared.download(from: archive)
        try requireSuccess(response)
        try Task.checkCancellation()

        let fm = FileManager.default
        let base = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true))
            ?? fm.temporaryDirectory
        let work = base.appendingPathComponent("MacRAR-update-\(UUID().uuidString)", isDirectory: true)
        let prepared = Prepared(app: work.appendingPathComponent("unpacked/MacRAR.app", isDirectory: true), work: work, base: base)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent(UpdateInfo.archiveName)
            try fm.moveItem(at: downloaded, to: zip)
            try verify(zip, expected: expected, app: prepared.app, version: release.version, bundleID: bundleID)
            try Task.checkCancellation()
            return prepared
        } catch {
            prepared.discard()
            throw error
        }
    }

    /// Yeni uygulamayı eskisinin yerine koyar. macOS çalışan bir paketin değiştirilmesine izin verir; eski kopya yeniden
    /// açılana dek çalışmayı sürdürür.
    public static func replace(appAt current: URL, with prepared: Prepared) throws {
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: prepared.app)
        } catch {
            throw Failure.notWritable(folder: current.deletingLastPathComponent().path, reason: error.localizedDescription)
        }
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.http(http.statusCode) }
    }

    private static func verify(_ zip: URL, expected: String, app: URL, version: String, bundleID: String) throws {
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
        guard digest.map({ String(format: "%02x", $0) }).joined() == expected else { throw Failure.checksumMismatch }

        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, app.deletingLastPathComponent().path]) else { throw Failure.unpackFailed }
        // Finder eklentisi olmayan bir paket menüyü sessizce kaldırırdı; o da beklenen uygulama sayılmaz.
        let fm = FileManager.default
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              fm.fileExists(atPath: app.appendingPathComponent(UpdateInfo.finderExtensionPath).path) else {
            throw Failure.wrongApp
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { throw Failure.badSignature }
        // Kullanıcı güncellemeyi az önce onayladı; macOS yeniden sormasın.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: Deneme derlemesi

    /// Yalnızca deneme derlemesinde okunur (scripts/build_app.sh debug); yayımlanan uygulamada bu ayarlar yoktur.
    /// MACRAR_UPDATE_URL başka bir sürüm bilgisi (ör. file:// ile sahte sürüm).
    public static var testURL: URL? {
        #if DEBUG
        ProcessInfo.processInfo.environment["MACRAR_UPDATE_URL"].flatMap(URL.init(string:))
        #else
        nil
        #endif
    }

    #if DEBUG
    /// MACRAR_UPDATE_TEST=1: denetler ve kurar, sonucu yazar, çıkar. Uygulama başlamadan çalışır: pencere açılmaz,
    /// Finder anahtarına ve durum dosyasına dokunulmaz.
    public static func runSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["MACRAR_UPDATE_TEST"] != nil else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let result: String
            do {
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                let release = try await fetchLatest()
                if UpdateInfo.isNewer(release.version, than: current) {
                    let prepared = try await prepare(release, replacing: Bundle.main.bundleURL, bundleID: Bundle.main.bundleIdentifier ?? "")
                    defer { prepared.discard() }
                    try replace(appAt: Bundle.main.bundleURL, with: prepared)
                    result = "installed \(release.version)\nwhatsNew: \(UpdateInfo.whatsNew(in: release.notes, turkish: false))"
                } else {
                    result = "upToDate \(current)"
                }
            } catch {
                result = "refused: \(error)"
            }
            FileHandle.standardError.write(Data("update test: \(result)\n".utf8))
            done.signal()
        }
        done.wait()
        exit(0)
    }
    #endif
}
