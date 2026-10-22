import Foundation

/// rar / unrar / bsdtar komut satırı araçlarının üstündeki yüksek seviyeli arşiv API'si.
public final class ArchiveService: Sendable {
    public let tools: ToolPaths

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    // MARK: Motor seçimi

    private static let rarMagic: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07] // "Rar!\x1A\x07"

    /// Dosyanın ilk baytlarına bakarak RAR olup olmadığını belirler (uzantıya güvenmez).
    public static func engine(for archive: URL) -> ArchiveEngine {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return .libarchive }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
        // SFX gövdesi olabilir; ilk 1 MB içinde imza ara.
        if head.range(of: Data(rarMagic)) != nil { return .rar }
        return .libarchive
    }

    // MARK: Listeleme

    public func list(archive: URL, password: String? = nil) async throws -> ArchiveListing {
        switch Self.engine(for: archive) {
        case .rar:
            if tools.usesUnarForRAR { return try await listWithUnar(archive: archive, password: password) }
            guard let tool = tools.rarReader else { throw ArchiveError.toolMissing(String(localized: "unrar (ya da unar)")) }
            let r = try await ProcessRunner.run(tool,
                                                ["lt", password == nil ? "-p-" : "-p", archive.path],
                                                stdin: Self.passwordInput(password))
            let parsed = RarListParser.parse(r.text)
            if parsed.entries.isEmpty {
                if parsed.passwordProblem { throw password == nil ? ArchiveError.passwordRequired : .wrongPassword }
                if r.exitCode != 0 || !parsed.recognizedArchive {
                    throw ArchiveError.failed(exitCode: r.exitCode, message: Self.errorSummary(r.text))
                }
            }
            return ArchiveListing(entries: parsed.entries, info: parsed.info, engine: .rar)

        case .libarchive:
            guard let tool = tools.bsdtar else { throw ArchiveError.toolMissing("bsdtar") }
            var args = ["-tvf", archive.path]
            args += Self.passphraseArgs(password)
            let r = try await ProcessRunner.run(tool, args, exactArguments: Self.exact(password), onOutput: Self.passphraseWatcher)
            if r.killedEarly || Self.mentionsPassphrase(r.text) {
                throw password == nil ? ArchiveError.passwordRequired : .wrongPassword
            }
            var entries = TarListParser.parse(r.text)
            if entries.isEmpty && r.exitCode != 0 {
                throw ArchiveError.failed(exitCode: r.exitCode, message: Self.errorSummary(r.text))
            }
            entries = await Self.addingZipDetails(to: entries, archive: archive)
            let ext = archive.pathExtension.uppercased()
            let info = ArchiveInfo(formatName: ext.isEmpty ? String(localized: "Arşiv") : ext)
            return ArchiveListing(entries: entries, info: info, engine: .libarchive)
        }
    }

    // MARK: Çıkarma

    /// - Parameter selection: nil ise arşivin tamamı çıkarılır. Klasör seçildiyse içeriğiyle birlikte çıkar.
    @discardableResult
    public func extract(archive: URL,
                        selection: [ArchiveEntry]?,
                        options: ExtractOptions,
                        password: String? = nil,
                        tracker: ProgressTracker? = nil) async throws -> OperationReport {
        try FileManager.default.createDirectory(at: options.destination, withIntermediateDirectories: true)
        let destArg = options.destination.path.hasSuffix("/") ? options.destination.path : options.destination.path + "/"

        switch Self.engine(for: archive) {
        case .rar:
            if tools.usesUnarForRAR {
                return try await extractWithUnar(archive: archive, selection: selection, options: options,
                                                 password: password, tracker: tracker)
            }
            guard let tool = tools.rarReader else { throw ArchiveError.toolMissing(String(localized: "unrar (ya da unar)")) }
            var args = [options.keepPaths ? "x" : "e", "-y"]
            switch options.overwrite {
            case .overwrite: args.append("-o+")
            case .skip: args.append("-o-")
            case .rename: args.append("-or")
            }
            if options.keepBroken { args.append("-kb") }
            args.append(password == nil ? "-p-" : "-p")
            args.append(archive.path)

            var listFile: URL?
            defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }
            if let selection {
                listFile = try Self.writeList(selection.map { $0.rawName })
                args.append("@" + listFile!.path)
            }
            args.append(destArg)

            let r = try await ProcessRunner.run(tool, args, stdin: Self.passwordInput(password)) { data in
                tracker?.feed(data); return false
            }
            tracker?.finish()
            return try Self.interpret(r, passwordGiven: password != nil)

        case .libarchive:
            guard let tool = tools.bsdtar else { throw ArchiveError.toolMissing("bsdtar") }
            var args = ["-xvf", archive.path, "-C", options.destination.path]
            if options.overwrite == .skip { args.append("-k") }
            args += Self.passphraseArgs(password)

            var listFile: URL?
            defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }
            if let selection {
                listFile = try Self.writeList(selection.map { $0.rawName })
                args += ["-T", listFile!.path]
            }
            let monitor = TransferMonitorBox()
            defer { monitor.cancel() }
            let destinationPath = options.destination.path
            let r = try await ProcessRunner.run(tool, args, exactArguments: Self.exact(password),
                                                onStart: { pid in
                                                    monitor.set(TransferMonitor.start(pid: pid, roots: [destinationPath], tracker: tracker))
                                                }) { data in
                tracker?.feed(data)
                return Self.passphraseWatcher(data)
            }
            monitor.cancel()
            tracker?.finish()
            if r.killedEarly || Self.mentionsPassphrase(r.text) {
                throw password == nil ? ArchiveError.passwordRequired : .wrongPassword
            }
            return try Self.interpretTar(r)
        }
    }

    /// Tek bir dosyayı geçici klasöre çıkarıp yolunu döndürür (görüntüleme / "birlikte aç" için).
    public func extractForPreview(archive: URL, entry: ArchiveEntry, password: String? = nil,
                                  tracker: ProgressTracker? = nil) async throws -> URL {
        try await extractToTemporary(archive: archive, root: entry, selection: [entry],
                                     password: password, tracker: tracker)
    }

    /// `selection` girdilerini (klasör seçildiyse içerikleriyle genişletilmiş hali) yeni bir geçici
    /// klasöre çıkarır ve `root` girdisinin diskteki yolunu döndürür. Sürükle-bırak ile çıkarma
    /// ve önizleme bunu kullanır. Çıkan öğeler arşivin karantina özniteliğini devralır.
    public func extractToTemporary(archive: URL, root: ArchiveEntry, selection: [ArchiveEntry],
                                   password: String? = nil, tracker: ProgressTracker? = nil) async throws -> URL {
        let dir = Self.temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try await extract(archive: archive, selection: selection,
                          options: ExtractOptions(destination: dir, overwrite: .overwrite, keepPaths: true),
                          password: password, tracker: tracker)
        let result = dir.appendingPathComponent(root.path)
        guard FileManager.default.fileExists(atPath: result.path) else {
            throw ArchiveError.failed(exitCode: 10, message: String(localized: "Dosya çıkarılamadı: \(root.path)"))
        }
        Quarantine.propagate(from: archive, to: selection.map { dir.appendingPathComponent($0.path) })
        return result
    }

    public static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacRAR", isDirectory: true)
    }

    /// Önizleme için açılan geçici dosyaları siler (uygulama kapanırken çağrılır).
    public static func cleanTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    // MARK: Sınama

    @discardableResult
    public func test(archive: URL, password: String? = nil, tracker: ProgressTracker? = nil) async throws -> OperationReport {
        guard Self.engine(for: archive) == .rar else {
            return try await testWithBsdtar(archive: archive, password: password, tracker: tracker)
        }
        if tools.usesUnarForRAR { return try await testWithUnar(archive: archive, password: password, tracker: tracker) }
        guard let tool = tools.rarReader else { throw ArchiveError.toolMissing(String(localized: "unrar (ya da unar)")) }
        let r = try await ProcessRunner.run(tool, ["t", "-y", password == nil ? "-p-" : "-p", archive.path],
                                            stdin: Self.passwordInput(password)) { data in
            tracker?.feed(data); return false
        }
        tracker?.finish()
        return try Self.interpret(r, passwordGiven: password != nil)
    }

    // MARK: Oluşturma / ekleme

    @discardableResult
    public func add(_ options: CompressOptions, tracker: ProgressTracker? = nil) async throws -> OperationReport {
        guard !options.sources.isEmpty else {
            throw ArchiveError.unsupported(String(localized: "Eklenecek dosya seçilmedi."))
        }
        if options.format.isRAR {
            return try await addRAR(options, tracker: tracker)
        }
        if options.format == .zip, options.appendToExisting {
            return try await addToZip(options, tracker: tracker)
        }
        return try await addLibarchive(options, tracker: tracker)
    }

    private func addRAR(_ o: CompressOptions, tracker: ProgressTracker?) async throws -> OperationReport {
        guard let tool = tools.rar else { throw ArchiveError.toolMissing("rar") }

        var args = [o.updateMode == .update ? "u" : "a", "-y", "-ep1", "-m\(o.method.rawValue)"]
        args.append(o.format == .rar4 ? "-ma4" : "-ma5")
        if o.format == .rar5, let d = o.dictionary, !d.isEmpty { args.append("-md\(d)") }
        args.append(o.solid ? "-s" : "-s-")
        if o.keepSymlinks { args.append("-ol") }
        if o.recoveryPercent > 0 { args.append("-rr\(o.recoveryPercent)p") }
        if o.testAfter { args.append("-t") }
        if o.deleteAfter { args.append("-df") }
        if o.lock { args.append("-k") }
        if let v = o.volumeSize, !v.isEmpty { args.append("-v\(v)") }
        if !o.pathInArchive.isEmpty { args.append("-ap\(o.pathInArchive)") }

        var stdin: Data?
        if let pw = o.password, !pw.isEmpty {
            args.append(o.encryptNames ? "-hp" : "-p")
            stdin = Data((pw + "\n" + pw + "\n").utf8) // parola + onay
        }

        var tempFiles: [URL] = []
        defer { for f in tempFiles { try? FileManager.default.removeItem(at: f) } }
        if let c = o.comment, !c.isEmpty {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-\(UUID().uuidString).txt")
            try c.write(to: f, atomically: true, encoding: .utf8)
            tempFiles.append(f)
            args.append("-z" + f.path)
        }

        // Gerçek yollar: rar adları verildiği gibi yazdırır; ilerleme izleme (açık dosya yolları gerçek yolla gelir) ve ağırlıklar
        // bu yolla eşleşir. Arşivdeki adlar -ep1 ile zaten yoldan bağımsızdır.
        let realSources = o.sources.map { TransferMonitor.realPath($0.path) }
        let list = try Self.writeList(realSources)
        tempFiles.append(list)
        args += [o.archive.path, "@" + list.path]

        let monitor = TransferMonitorBox()
        defer { monitor.cancel() }
        let r = try await ProcessRunner.run(tool, args, currentDirectory: Self.workDirectory(for: o.archive), stdin: stdin,
                                            onStart: { pid in
                                                monitor.set(TransferMonitor.start(pid: pid, roots: realSources, absolute: true, tracker: tracker))
                                            }) { data in
            tracker?.feed(data); return false
        }
        monitor.cancel()
        tracker?.finish()
        var report = try Self.interpret(r, passwordGiven: false)
        report.outputFiles = [o.archive]
        return report
    }

    private func addLibarchive(_ o: CompressOptions, tracker: ProgressTracker?) async throws -> OperationReport {
        guard let tool = tools.bsdtar else { throw ArchiveError.toolMissing("bsdtar") }
        var args: [String]
        switch o.format {
        case .zip:
            args = ["--format", "zip"]
            var opts: [String] = []
            if o.method == .store { opts.append("zip:compression=store") }
            if let pw = o.password, !pw.isEmpty {
                opts.append("zip:encryption=aes256")
                args += ["--passphrase", pw]
            }
            if !opts.isEmpty { args += ["--options", opts.joined(separator: ",")] }
            args += ["-cvf", o.archive.path]
        case .sevenZip: args = ["--format", "7zip", "-cvf", o.archive.path]
        case .tarGz: args = ["-czvf", o.archive.path]
        case .tarBz2: args = ["-cjvf", o.archive.path]
        case .tarXz: args = ["-cJvf", o.archive.path]
        default: throw ArchiveError.unsupported(String(localized: "Desteklenmeyen biçim."))
        }
        try? FileManager.default.removeItem(at: o.archive) // bsdtar mevcut dosyanın üstüne yazar
        for src in o.sources {
            args += ["-C", src.deletingLastPathComponent().path, src.lastPathComponent]
        }
        let monitor = TransferMonitorBox()
        defer { monitor.cancel() }
        let sourceRoots = o.sources.map { $0.deletingLastPathComponent().path }
        let r = try await ProcessRunner.run(tool, args,
                                            environment: ["COPYFILE_DISABLE": "1"],
                                            exactArguments: Self.exact(o.password),
                                            onStart: { pid in
                                                monitor.set(TransferMonitor.start(pid: pid, roots: sourceRoots, tracker: tracker))
                                            }) { data in
            tracker?.feed(data); return false
        }
        monitor.cancel()
        tracker?.finish()
        var report = try Self.interpretTar(r)
        report.outputFiles = [o.archive]
        if o.deleteAfter {
            for s in o.sources { try? FileManager.default.removeItem(at: s) }
        }
        return report
    }

    // MARK: Arşiv düzenleme (RAR; ZIP için bkz. ZipEditing.swift)

    /// rar, arşivi değiştirirken geçici `__rar_….rartemp` dosyasını ÇALIŞMA KLASÖRÜNDE oluşturur. Finder/Dock'tan açılan bir
    /// uygulamanın çalışma klasörü `/` (salt okunur) olduğundan düzenleme "Cannot create …rartemp" ile çöküyordu.
    /// Arşivin kendi klasörü kullanılır: yazılabilir ve aynı birimde (büyük arşivlerde kopyalama yok).
    static func workDirectory(for archive: URL) -> URL {
        archive.deletingLastPathComponent()
    }

    @discardableResult
    public func delete(from archive: URL, entries: [ArchiveEntry], password: String? = nil,
                       tracker: ProgressTracker? = nil) async throws -> OperationReport {
        if Self.isZIP(archive) {
            return try await deleteFromZip(archive: archive, entries: entries, password: password, tracker: tracker)
        }
        guard let tool = tools.rar else { throw ArchiveError.toolMissing("rar") }
        try Self.requireRAR(archive)
        var names: [String] = []
        for e in entries {
            names.append(e.rawName)
            if e.isDirectory { names.append(e.rawName + "/*") }
        }
        let list = try Self.writeList(names)
        defer { try? FileManager.default.removeItem(at: list) }
        let r = try await ProcessRunner.run(tool,
                                            ["d", "-y", password == nil ? "-p-" : "-p", archive.path, "@" + list.path],
                                            currentDirectory: Self.workDirectory(for: archive),
                                            stdin: Self.passwordInput(password)) { data in
            tracker?.feed(data); return false
        }
        tracker?.finish()
        return try Self.interpret(r, passwordGiven: password != nil)
    }

    @discardableResult
    public func rename(in archive: URL, entry: ArchiveEntry, newPath: String, password: String? = nil) async throws -> OperationReport {
        if Self.isZIP(archive) {
            return try await renameInZip(archive: archive, entry: entry, newPath: newPath, password: password)
        }
        guard let tool = tools.rar else { throw ArchiveError.toolMissing("rar") }
        try Self.requireRAR(archive)
        let r = try await ProcessRunner.run(tool,
                                            ["rn", "-y", password == nil ? "-p-" : "-p", archive.path, entry.rawName, newPath],
                                            currentDirectory: Self.workDirectory(for: archive),
                                            stdin: Self.passwordInput(password))
        return try Self.interpret(r, passwordGiven: password != nil)
    }

    @discardableResult
    public func setComment(archive: URL, comment: String, password: String? = nil) async throws -> OperationReport {
        guard let tool = tools.rar else { throw ArchiveError.toolMissing("rar") }
        try Self.requireRAR(archive)
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-\(UUID().uuidString).txt")
        try comment.write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        let args = ["c", "-y", password == nil ? "-p-" : "-p", "-z" + f.path, archive.path]
        let r = try await ProcessRunner.run(tool, args, currentDirectory: Self.workDirectory(for: archive),
                                            stdin: Self.passwordInput(password))
        return try Self.interpret(r, passwordGiven: password != nil)
    }

    @discardableResult
    public func addRecoveryRecord(archive: URL, percent: Int, password: String? = nil) async throws -> OperationReport {
        guard let tool = tools.rar else { throw ArchiveError.toolMissing("rar") }
        try Self.requireRAR(archive)
        let r = try await ProcessRunner.run(tool,
                                            ["rr\(percent)p", "-y", password == nil ? "-p-" : "-p", archive.path],
                                            currentDirectory: Self.workDirectory(for: archive),
                                            stdin: Self.passwordInput(password))
        return try Self.interpret(r, passwordGiven: password != nil)
    }

    @discardableResult
    public func lock(archive: URL) async throws -> OperationReport {
        guard let tool = tools.rar else { throw ArchiveError.toolMissing("rar") }
        try Self.requireRAR(archive)
        let r = try await ProcessRunner.run(tool, ["k", "-y", archive.path], currentDirectory: Self.workDirectory(for: archive))
        return try Self.interpret(r, passwordGiven: false)
    }

    /// Bozuk arşivi onarır; sonuç aynı klasörde `fixed.<ad>.rar` olarak oluşur.
    public func repair(archive: URL, tracker: ProgressTracker? = nil) async throws -> URL {
        guard let tool = tools.rar else { throw ArchiveError.toolMissing("rar") }
        try Self.requireRAR(archive)
        let dir = archive.deletingLastPathComponent()
        let r = try await ProcessRunner.run(tool, ["r", "-y", archive.lastPathComponent], currentDirectory: dir) { data in
            tracker?.feed(data); return false
        }
        tracker?.finish()
        _ = try Self.interpret(r, passwordGiven: false)
        let fixed = dir.appendingPathComponent("fixed." + archive.lastPathComponent)
        let rebuilt = dir.appendingPathComponent("rebuilt." + archive.lastPathComponent)
        if FileManager.default.fileExists(atPath: fixed.path) { return fixed }
        if FileManager.default.fileExists(atPath: rebuilt.path) { return rebuilt }
        throw ArchiveError.failed(exitCode: 2, message: String(localized: "Onarım çıktısı bulunamadı.") + "\n" + Self.errorSummary(r.text))
    }

    /// ZIP/7Z/TAR sınaması: tüm veri okunup çıktısı atılır (bsdtar sıkıştırma ve CRC denetimini okurken yapar).
    private func testWithBsdtar(archive: URL, password: String?, tracker: ProgressTracker?) async throws -> OperationReport {
        guard let tool = tools.bsdtar else { throw ArchiveError.toolMissing("bsdtar") }
        // Dosya içeriği stdout'a akar ve hata iletileriyle aynı boruya karışırdı (ve bellekte birikirdi): stdout /dev/null'a atılır.
        let args = ["-c", "exec \"$0\" \"$@\" >/dev/null", tool.path, "-xOf", archive.path] + Self.passphraseArgs(password)
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), args, exactArguments: Self.exact(password)) { data in
            Self.passphraseWatcher(data)
        }
        tracker?.finish()
        if r.killedEarly || Self.mentionsPassphrase(r.text) {
            throw password == nil ? ArchiveError.passwordRequired : .wrongPassword
        }
        return try Self.interpretTar(r)
    }

    // MARK: unar / lsar yolu (unrar ve rar yokken RAR'ı açmak için; salt okunur)

    /// Bu motorla çıkarma/sınama çıktısını ilerleme izleyicisine hangi biçimde vermeli.
    public func progressStyle(for engine: ArchiveEngine) -> ProgressParser.Style {
        switch engine {
        case .libarchive: return .bsdtar
        case .rar: return tools.usesUnarForRAR ? .unar : .rar
        }
    }

    private func listWithUnar(archive: URL, password: String?) async throws -> ArchiveListing {
        guard let lsar = tools.lsar else { throw ArchiveError.toolMissing("lsar") }
        var args = ["-j", "-jss"] // JSON, katı-arşiv bilgisi olmadan (büyük arşivlerde çıktıyı küçültür)
        if let pw = password, !pw.isEmpty { args += ["-p", pw] }
        args.append(archive.path)
        let r = try await ProcessRunner.run(lsar, args, exactArguments: Self.exact(password))

        // Ölçülen davranış: çıkış 2 = parola gerekli; çıkış 1 + lsarError 15 = yanlış parola
        if r.exitCode == 2 || r.text.contains("requires a password") {
            throw password == nil ? ArchiveError.passwordRequired : .wrongPassword
        }
        guard let parsed = UnarListParser.parse(r.output) else {
            throw ArchiveError.failed(exitCode: r.exitCode, message: Self.errorSummary(r.text))
        }
        if parsed.errorCode == 15 { throw password == nil ? ArchiveError.passwordRequired : .wrongPassword }
        if parsed.entries.isEmpty, parsed.errorCode != nil || r.exitCode != 0 {
            let msg = parsed.errorCode == 0 ? String(localized: "Bu dosya geçerli bir RAR arşivi olarak tanınmadı.") : Self.errorSummary(r.text)
            throw ArchiveError.failed(exitCode: r.exitCode, message: msg)
        }
        let info = ArchiveInfo(formatName: parsed.formatName.isEmpty ? "RAR" : parsed.formatName)
        return ArchiveListing(entries: parsed.entries, info: info, engine: .rar)
    }

    private func extractWithUnar(archive: URL, selection: [ArchiveEntry]?, options: ExtractOptions,
                                 password: String?, tracker: ProgressTracker?) async throws -> OperationReport {
        guard let unar = tools.unar else { throw ArchiveError.toolMissing("unar") }
        guard options.keepPaths else {
            throw ArchiveError.unsupported(String(localized: "Klasör yapısı olmadan çıkarma için unrar veya rar gerekir; unar bunu desteklemiyor."))
        }
        // -D: arşiv adıyla ek bir klasör açma (unrar x ile aynı yerleşim)
        var args = ["-D", "-o", options.destination.path]
        switch options.overwrite {
        case .overwrite: args.append("-f")
        case .skip: args.append("-s")
        case .rename: args.append("-r")
        }
        if let pw = password, !pw.isEmpty { args += ["-p", pw] }
        if let selection {
            // Ad/joker karakter eşleşmesi yerine arşiv sıra numarasıyla (-i): özel karakterli adlarda da tam eşleşir.
            let indexes = selection.compactMap(\.index)
            guard !indexes.isEmpty else {
                throw ArchiveError.failed(exitCode: 10, message: String(localized: "Çıkarılacak öğe bulunamadı."))
            }
            args += ["-i", archive.path] + indexes.map(String.init)
        } else {
            args.append(archive.path)
        }
        let r = try await ProcessRunner.run(unar, args, exactArguments: Self.exact(password)) { data in tracker?.feed(data); return false }
        tracker?.finish()
        return try Self.interpretUnar(r, passwordGiven: password != nil)
    }

    private func testWithUnar(archive: URL, password: String?, tracker: ProgressTracker?) async throws -> OperationReport {
        guard let lsar = tools.lsar else { throw ArchiveError.toolMissing("lsar") }
        var args = ["-t"]
        if let pw = password, !pw.isEmpty { args += ["-p", pw] }
        args.append(archive.path)
        let r = try await ProcessRunner.run(lsar, args, exactArguments: Self.exact(password)) { data in tracker?.feed(data); return false }
        tracker?.finish()
        return try Self.interpretUnar(r, passwordGiven: password != nil)
    }

    /// unar/lsar çıkış kodları (ölçüldü): 0 başarı, 2 parola gerekli, 1 hata (yanlış parola dahil).
    static func interpretUnar(_ r: ProcessResult, passwordGiven: Bool) throws -> OperationReport {
        if r.exitCode == 0 { return OperationReport() }
        let text = r.text
        if r.exitCode == 2 || text.contains("requires a password") {
            throw passwordGiven ? ArchiveError.wrongPassword : .passwordRequired
        }
        if text.contains("wrong password") || text.contains("Missing or wrong password") {
            throw passwordGiven ? ArchiveError.wrongPassword : .passwordRequired
        }
        throw ArchiveError.failed(exitCode: r.exitCode, message: errorSummary(text))
    }

    // MARK: Yardımcılar

    private static func requireRAR(_ archive: URL) throws {
        guard engine(for: archive) == .rar else {
            throw ArchiveError.unsupported(String(localized: "Bu işlem yalnızca RAR arşivleri için desteklenir."))
        }
    }

    /// Parolayı komut satırında göstermemek için stdin üzerinden veririz ("-p" değersiz).
    static func passwordInput(_ password: String?) -> Data? {
        guard let password else { return nil }
        return Data((password + "\n").utf8)
    }

    static func passphraseArgs(_ password: String?) -> [String] {
        guard let password, !password.isEmpty else { return [] }
        return ["--passphrase", password]
    }

    /// Komut satırında geçen parolanın baytı baytına iletilmesi için `ProcessRunner.exactArguments` değeri.
    static func exact(_ password: String?) -> [String] { password.map { [$0] } ?? [] }

    static func mentionsPassphrase(_ text: String) -> Bool {
        text.range(of: "passphrase", options: .caseInsensitive) != nil
    }

    /// bsdtar bilinmeyen parolada tekrar tekrar "Enter passphrase" yazar; görür görmez sonlandır.
    static let passphraseWatcher: @Sendable (Data) -> Bool = { data in
        String(decoding: data, as: UTF8.self).range(of: "passphrase", options: .caseInsensitive) != nil
    }

    static func writeList(_ names: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-\(UUID().uuidString).lst")
        try (names.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Çıktıdan kullanıcıya gösterilecek hata satırlarını seçer.
    static func errorSummary(_ text: String) -> String {
        let keys = ["ERROR", "Cannot", "cannot", "failed", "Failed", "Checksum", "Incorrect", "No files",
                    "is not RAR", "Unexpected end", "Corrupt", "corrupt", "bsdtar:", "Locked", "Couldn't", "Unpacking failed"]
        var picked: [String] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\u{8}" }) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if keys.contains(where: { l.contains($0) }), !picked.contains(l) { picked.append(l) }
        }
        return picked.suffix(6).joined(separator: "\n")
    }

    static func interpret(_ r: ProcessResult, passwordGiven: Bool) throws -> OperationReport {
        let text = r.text
        switch r.exitCode {
        case 0:
            return OperationReport()
        case 1:
            let s = errorSummary(text)
            return OperationReport(warnings: s.isEmpty ? [] : s.components(separatedBy: "\n"))
        case 11:
            throw passwordGiven ? ArchiveError.wrongPassword : .passwordRequired
        case 3 where text.contains("wrong password") || text.contains("encrypted file"):
            throw passwordGiven ? ArchiveError.wrongPassword : .passwordRequired
        default:
            throw ArchiveError.failed(exitCode: r.exitCode, message: errorSummary(text))
        }
    }

    static func interpretTar(_ r: ProcessResult) throws -> OperationReport {
        if r.exitCode == 0 { return OperationReport() }
        throw ArchiveError.failed(exitCode: r.exitCode, message: errorSummary(r.text))
    }
}

// MARK: - Seçim yardımcıları

public enum ArchiveSelection {
    /// Seçilen girdileri (klasörler içerikleriyle) arşivdeki tüm girdiler arasında genişletir.
    public static func expand(_ selection: [ArchiveEntry], in all: [ArchiveEntry]) -> [ArchiveEntry] {
        let selected = Set(selection.map { $0.path })
        return all.filter { entry in
            if selected.contains(entry.path) { return true }
            var p = entry.parentPath
            while !p.isEmpty {
                if selected.contains(p) { return true }
                if let slash = p.lastIndex(of: "/") { p = String(p[..<slash]) } else { break }
            }
            return false
        }
    }
}

// MARK: - İlerleme izleyici fabrikaları

public extension ProgressTracker {
    /// Çıkarma için: ağırlıklar dosya boyutlarıdır.
    static func forExtraction(entries: [ArchiveEntry], destination: URL, flatten: Bool,
                              engine: ArchiveEngine, style: ProgressParser.Style? = nil) -> ProgressTracker {
        var weights: [String: Int64] = [:]
        weights.reserveCapacity(entries.count)
        for e in entries where !e.isDirectory {
            let key = flatten ? e.name : e.path
            weights[key] = e.size
        }
        var prefix = destination.path
        if !prefix.hasSuffix("/") { prefix += "/" }
        let resolved = style ?? (engine == .rar ? .rar : .bsdtar)
        // Yalnızca rar/unrar hedef yolu başa ekleyerek yazdırır; unar ve bsdtar göreli adlarla yazdırır.
        return ProgressTracker(weights: weights,
                               stripPrefix: resolved == .rar ? prefix : "",
                               flatten: flatten,
                               style: resolved)
    }

    /// Ekleme için: kaynak ağacını gezip arşivdeki adlarla boyutları eşler.
    static func forAdding(_ options: CompressOptions) async -> ProgressTracker {
        // rar, ekleme sırasında adları kaynağın verilen (mutlak, gerçek) yoluyla yazdırır; bsdtar ise
        // -C ile verilen göreli adla. İlerleme eşlemesi için aynı anahtarı üretmeliyiz.
        let absolute = options.format.isRAR
        let sources = absolute ? options.sources.map { URL(fileURLWithPath: TransferMonitor.realPath($0.path)) } : options.sources
        let weights = await Task.detached { scanSources(sources, absolute: absolute) }.value
        // Mevcut ZIP'e ekleme: bsdtar adları arşiv içi klasör ön ekiyle yazdırır.
        var stripPrefix = ""
        if options.format == .zip, options.appendToExisting {
            let p = options.pathInArchive.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !p.isEmpty { stripPrefix = p + "/" }
        }
        return ProgressTracker(weights: weights, stripPrefix: stripPrefix, style: options.format.isRAR ? .rar : .bsdtar)
    }
}

/// Senkron dosya ağacı taraması (async bağlamdan ayrı tutulur).
private func scanSources(_ sources: [URL], absolute: Bool) -> [String: Int64] {
    var w: [String: Int64] = [:]
    let fm = FileManager.default
    for src in sources {
        let base = absolute ? src.path : src.lastPathComponent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
        if !isDir.boolValue {
            w[base] = ((try? fm.attributesOfItem(atPath: src.path)[.size]) as? NSNumber)?.int64Value ?? 0
            continue
        }
        guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                     options: []) else { continue }
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true { continue }
            // Göreli yol: enumerator'ın derinliği kadar son bileşen (/var ↔ /private/var farkından etkilenmez).
            let rel = url.pathComponents.suffix(en.level).joined(separator: "/")
            w[base + "/" + rel] = Int64(vals?.fileSize ?? 0)
        }
    }
    return w
}
