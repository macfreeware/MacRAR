import Foundation

/// RARLAB'ın resmi "RAR for macOS" komut satırı paketini rarlab.com'dan indirip kullanıcının klasörüne kurar.
///
/// - Paket MacRAR'ın içinde dağıtılmaz; kullanıcının isteğiyle doğrudan RARLAB'dan indirilir (lisans gereği).
/// - Yönetici parolası gerekmez: araçlar `~/Library/Application Support/MacRAR/tools/rar` altına kurulur
///   ve `ToolPaths` bu klasöre de bakar. `URLSession` ile inen dosyaya karantina işareti konmadığından
///   Gatekeeper engeli de oluşmaz.
/// - Yalnızca `https://www.rarlab.com` adresinden (yönlendirmeler dahil) indirilir; indirilen paket açılıp
///   `rar`/`unrar` gerçekten çalıştırılarak doğrulanmadan kuruma geçilmez.
public enum RARInstaller {
    public static let allowedHost = "www.rarlab.com"
    /// En fazla kabul edilen paket boyutu (resmi paket ~0,7 MB).
    public static let maxDownloadBytes = 20 * 1024 * 1024

    public static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacRAR/tools/rar", isDirectory: true)
    }

    /// Uygulama paketine konan ücretsiz `unrar` (bkz. scripts/fetch_unrar.sh); uygulama dışında (testler) nil.
    public static var bundledUnrarDirectory: URL? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.resourceURL?.appendingPathComponent("unrar/\(currentArch)", isDirectory: true)
    }

    /// Bu Mac'in mimarisine uygun RARLAB paket adı parçası.
    public static var currentArch: String {
        #if arch(arm64)
        return "arm"
        #else
        return "x64"
        #endif
    }

    public struct Package: Equatable, Sendable {
        public let version: String   // örn. "7.23"
        public let url: URL
    }

    public struct Installed: Equatable, Sendable {
        public let version: String
        public let directory: URL
    }

    public enum InstallError: Error, LocalizedError, Equatable {
        case pageUnreadable
        case noPackage
        case untrustedURL(String)
        case tooLarge
        case download(String)
        case extract(String)
        case missingFiles
        case verification(String)
        case install(String)

        public var errorDescription: String? {
            switch self {
            case .pageUnreadable: String(localized: "RARLAB indirme sayfası okunamadı. İnternet bağlantınızı denetleyin.")
            case .noPackage: String(localized: "RARLAB sayfasında bu Mac için macOS paketi bulunamadı.")
            case .untrustedURL(let u): String(localized: "Güvenilmeyen indirme adresi reddedildi: \(u)")
            case .tooLarge: String(localized: "İndirilen dosya beklenenden büyük; kurulum durduruldu.")
            case .download(let m): String(localized: "İndirme başarısız: \(m)")
            case .extract(let m): String(localized: "Paket açılamadı: \(m)")
            case .missingFiles: String(localized: "İndirilen pakette rar/unrar bulunamadı.")
            case .verification(let m): String(localized: "İndirilen araç doğrulanamadı: \(m)")
            case .install(let m): String(localized: "Kurulamadı: \(m)")
            }
        }
    }

    /// Güvenlik duvarı/ağ izni penceresi ilk bağlantıda kullanıcıyı bekletebilir; zaman aşımı buna göre geniş tutulur.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// Ağ erişimi (testlerde değiştirilebilir).
    public struct Fetcher: Sendable {
        public var page: @Sendable (URL) async throws -> String
        public var download: @Sendable (URL, URL) async throws -> Void   // (kaynak, hedef dosya)
        public init(page: @escaping @Sendable (URL) async throws -> String,
                    download: @escaping @Sendable (URL, URL) async throws -> Void) {
            self.page = page
            self.download = download
        }

        public static let live = Fetcher(
            page: { url in
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      response.url?.host == RARInstaller.allowedHost else { throw InstallError.pageUnreadable }
                return String(decoding: data, as: UTF8.self)
            },
            download: { url, dest in
                let (tmp, response) = try await session.download(from: url)
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw InstallError.download(String(localized: "sunucu yanıtı beklenen gibi değil"))
                }
                guard response.url?.host == RARInstaller.allowedHost, response.url?.scheme == "https" else {
                    throw InstallError.untrustedURL(response.url?.absoluteString ?? "?")
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
                guard size > 0, size <= RARInstaller.maxDownloadBytes else { throw InstallError.tooLarge }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
            })
    }

    // MARK: Sayfa çözümleme

    /// İndirme sayfasındaki kararlı (beta olmayan) en yeni `rarmacos-<arch>-<sürüm>.tar.gz` bağlantısını bulur.
    public static func parsePackage(html: String, base: URL = ToolGuidance.rarlabDownloadURL,
                                    arch: String = currentArch) -> Package? {
        let pattern = #"href\s*=\s*["']([^"']*rarmacos-\#(arch)-(\d+)\.tar\.gz)["']"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        var best: (number: Int, digits: String, href: String)?
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
            let digits = ns.substring(with: m.range(at: 2))
            guard let number = Int(digits) else { continue }
            if best == nil || number > best!.number { best = (number, digits, href) }
        }
        guard let best, let url = URL(string: best.href, relativeTo: base)?.absoluteURL else { return nil }
        return Package(version: formatVersion(best.digits), url: url)
    }

    /// "723" → "7.23", "70" → "7.0"
    static func formatVersion(_ digits: String) -> String {
        guard digits.count >= 2 else { return digits }
        return "\(digits.prefix(1)).\(digits.dropFirst())"
    }

    // MARK: Kurulum

    /// Paketi indirir, doğrular ve `destination` klasörüne kurar. Var olan kurulumun yerine geçer.
    public static func install(fetcher: Fetcher = .live,
                               destination: URL = installDirectory,
                               arch: String = currentArch,
                               progress: @Sendable (String) -> Void = { _ in }) async throws -> Installed {
        let fm = FileManager.default

        progress(String(localized: "RARLAB sayfası okunuyor…"))
        let html: String
        do { html = try await fetcher.page(ToolGuidance.rarlabDownloadURL) }
        catch let e as InstallError { throw e }
        catch { throw InstallError.pageUnreadable }
        guard let package = parsePackage(html: html, arch: arch) else { throw InstallError.noPackage }
        guard package.url.scheme == "https", package.url.host == allowedHost else {
            throw InstallError.untrustedURL(package.url.absoluteString)
        }

        let work = fm.temporaryDirectory.appendingPathComponent("macrar-rar-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        progress(String(localized: "RAR \(package.version) indiriliyor…"))
        let archive = work.appendingPathComponent("rar.tar.gz")
        do { try await fetcher.download(package.url, archive) }
        catch let e as InstallError { throw e }
        catch { throw InstallError.download(error.localizedDescription) }

        progress(String(localized: "Paket açılıyor…"))
        let extracted = work.appendingPathComponent("x", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let tar = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                              ["-xzf", archive.path, "-C", extracted.path])
        guard tar.exitCode == 0 else { throw InstallError.extract(tar.text.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let source = extracted.appendingPathComponent("rar", isDirectory: true)
        func regularFile(_ name: String) -> URL? {
            let url = source.appendingPathComponent(name)
            let type = (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) ?? nil
            return type == .typeRegular ? url : nil
        }
        guard let rar = regularFile("rar"), let unrar = regularFile("unrar") else { throw InstallError.missingFiles }
        for tool in [rar, unrar] { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path) }

        progress(String(localized: "Araçlar doğrulanıyor…"))
        try await verify(rar, expecting: #"(?m)^RAR \d+\.\d+"#)
        try await verify(unrar, expecting: #"(?m)^UNRAR \d+\.\d+"#)

        progress(String(localized: "Kuruluyor…"))
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".rar-yeni-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in ["rar", "unrar", "default.sfx", "rarfiles.lst", "license.txt"] {
                if let file = regularFile(name) { try fm.copyItem(at: file, to: staging.appendingPathComponent(name)) }
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw InstallError.install(error.localizedDescription)
        }
        // Karantina işareti (varsa) kalksın; yoksa komut zararsızca başarısız olur.
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                                         ["-dr", "com.apple.quarantine", destination.path])
        progress(String(localized: "RAR \(package.version) kuruldu."))
        return Installed(version: package.version, directory: destination)
    }

    /// Aracı argümansız çalıştırıp başlık satırını denetler.
    private static func verify(_ tool: URL, expecting pattern: String) async throws {
        let r: ProcessResult
        do { r = try await ProcessRunner.run(tool, []) }
        catch { throw InstallError.verification(String(localized: "\(tool.lastPathComponent) çalıştırılamadı (\(error.localizedDescription))")) }
        guard r.text.range(of: pattern, options: .regularExpression) != nil else {
            throw InstallError.verification(String(localized: "\(tool.lastPathComponent) beklenen çıktıyı vermedi"))
        }
    }
}
