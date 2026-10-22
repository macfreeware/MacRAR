import Foundation

/// ZIP arşivlerini düzenleme (ekleme, silme, yeniden adlandırma).
///
/// ZIP için yerinde düzenleme aracı yoktur; bu yüzden arşiv `bsdtar` ile **yeni bir geçici dosyaya** yeniden yazılır ve
/// bitince asıl dosyanın yerine atomik olarak konur (hata/iptalde asıl arşive dokunulmaz).
///
/// - Parolasız arşiv: `bsdtar -c … @eski.zip` ile eski girdiler akıtılarak kopyalanır (diske açmadan). Silinecekler `-X` ile
///   dışlanır, yeniden adlandırma `-s` ile yapılır. Yeni dosyalar, adı değişmesin diye `macrar-new/` altında sembolik
///   bağlantılarla hazırlanır (`-H` bağlantıyı izler) ve `-s` ile `macrar-new/` → arşiv içi klasör olarak çevrilir.
///   Böylece `-X`, yalnızca ESKİ girdilerdeki aynı adlı kayıtları eler (yeni dosya eskisinin yerini alır).
/// - Parolalı (AES-256) arşiv: bsdtar aynı çağrıda hem okuyup hem şifreli yazamaz (kütüphane hatası), bu yüzden arşiv geçici
///   klasöre açılır, değişiklik uygulanır ve aynı parolayla yeniden paketlenir.
extension ArchiveService {
    /// Dosya bir ZIP arşivi mi (ilk baytlara bakılır; uzantıya güvenilmez)?
    public static func isZIP(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 4)) ?? Data())
        return head == [0x50, 0x4B, 0x03, 0x04] || head == [0x50, 0x4B, 0x05, 0x06]
    }

    static let zipStageToken = "macrar-new"

    // MARK: Genel API (delete / rename / add içinden çağrılır)

    func deleteFromZip(archive: URL, entries: [ArchiveEntry], password: String?, tracker: ProgressTracker?) async throws -> OperationReport {
        try Self.requirePasswordIfEncrypted(archive, password)
        let all = try await list(archive: archive, password: password).entries
        let doomed = ArchiveSelection.expand(entries, in: all)
        guard !doomed.isEmpty else { throw ArchiveError.failed(exitCode: 10, message: "") }
        if let password, !password.isEmpty {
            return try await rebuildEncryptedZip(archive: archive, password: password, tracker: tracker, sources: []) { work in
                for e in doomed.sorted(by: { $0.path.count > $1.path.count }) {
                    try? FileManager.default.removeItem(at: work.appendingPathComponent(e.path))
                }
            }
        }
        let patterns = doomed.map { Self.globPattern(forEntryName: $0.rawName) }
        return try await rewriteZip(archive: archive, excludePatterns: patterns, substitutions: [], stage: nil,
                                    tracker: tracker, monitorRoots: [])
    }

    func renameInZip(archive: URL, entry: ArchiveEntry, newPath: String, password: String?) async throws -> OperationReport {
        try Self.requirePasswordIfEncrypted(archive, password)
        let all = try await list(archive: archive, password: password).entries
        let normalizedNew = newPath.precomposedStringWithCanonicalMapping
        if all.contains(where: {
            let p = $0.path.precomposedStringWithCanonicalMapping
            return p == normalizedNew || p.hasPrefix(normalizedNew + "/")
        }) {
            throw ArchiveError.unsupported(String(localized: "“\(newPath)” adlı bir öğe arşivde zaten var."))
        }
        if let password, !password.isEmpty {
            return try await rebuildEncryptedZip(archive: archive, password: password, tracker: nil, sources: []) { work in
                let dest = work.appendingPathComponent(newPath)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: work.appendingPathComponent(entry.path), to: dest)
            }
        }
        // Ham ad "./klasör/" gibi gelebilir: ön eki koru.
        let dotSlash = entry.rawName.hasPrefix("./") ? "./" : ""
        var oldBase = entry.rawName
        while oldBase.hasPrefix("./") { oldBase.removeFirst(2) }
        while oldBase.hasSuffix("/") { oldBase.removeLast() }
        let newBase = dotSlash + newPath
        let oldPrefix = dotSlash + oldBase
        var subs = [try Self.substitution(from: "^" + Self.regexEscape(oldPrefix) + "$", to: newBase)]
        if entry.isDirectory {
            subs.append(try Self.substitution(from: "^" + Self.regexEscape(oldPrefix + "/"), to: newBase + "/"))
        }
        return try await rewriteZip(archive: archive, excludePatterns: [], substitutions: subs, stage: nil,
                                    tracker: nil, monitorRoots: [])
    }

    func addToZip(_ o: CompressOptions, tracker: ProgressTracker?) async throws -> OperationReport {
        guard Self.isZIP(o.archive) else {
            throw ArchiveError.unsupported(String(localized: "Bu dosya geçerli bir ZIP arşivi değil."))
        }
        let password = o.password.flatMap { $0.isEmpty ? nil : $0 }
        try Self.requirePasswordIfEncrypted(o.archive, password)
        let prefix = o.pathInArchive.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sourceRoots = o.sources.map { $0.deletingLastPathComponent().path }

        var report: OperationReport
        if let password {
            report = try await rebuildEncryptedZip(archive: o.archive, password: password, tracker: tracker,
                                                   sources: o.sources, monitorRoots: sourceRoots) { work in
                let base = prefix.isEmpty ? work : work.appendingPathComponent(prefix, isDirectory: true)
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                for src in o.sources {
                    try Self.mergeCopy(src, to: base.appendingPathComponent(src.lastPathComponent))
                }
            }
        } else {
            let oldEntries = try await list(archive: o.archive).entries
            let incoming = Self.incomingNames(for: o.sources, prefix: prefix)
            var patterns: [String] = []
            for old in oldEntries {
                var raw = old.rawName
                while raw.hasPrefix("./") { raw.removeFirst(2) }
                if incoming.contains(raw.precomposedStringWithCanonicalMapping) {
                    patterns.append(Self.globPattern(forEntryName: old.rawName))
                }
            }
            let stage = try Self.makeStage(for: o.sources)
            defer { try? FileManager.default.removeItem(at: stage.root) }
            let target = prefix.isEmpty ? "" : prefix + "/"
            let sub = try Self.substitution(from: "^" + Self.regexEscape(Self.zipStageToken + "/"), to: target)
            report = try await rewriteZip(archive: o.archive, excludePatterns: patterns, substitutions: [sub],
                                          stage: stage, tracker: tracker, monitorRoots: sourceRoots)
        }
        report.outputFiles = [o.archive]
        if o.deleteAfter {
            for s in o.sources { try? FileManager.default.removeItem(at: s) }
        }
        return report
    }

    // MARK: Parolasız: akıtarak yeniden yazma

    struct ZipStage {
        let root: URL
        /// `bsdtar` komut satırına verilecek göreli adlar (`macrar-new/<ad>`).
        let items: [String]
    }

    private func rewriteZip(archive: URL, excludePatterns: [String], substitutions: [String], stage: ZipStage?,
                            tracker: ProgressTracker?, monitorRoots: [String]) async throws -> OperationReport {
        guard let tool = tools.bsdtar else { throw ArchiveError.toolMissing("bsdtar") }
        let fm = FileManager.default
        let dir = archive.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(archive.lastPathComponent).macrar-\(UUID().uuidString).tmp")
        var excludeFile: URL?
        defer {
            try? fm.removeItem(at: tmp)
            if let excludeFile { try? fm.removeItem(at: excludeFile) }
        }

        var args = ["--format", "zip", "-H", "-cvf", tmp.path]
        if !excludePatterns.isEmpty {
            excludeFile = try Self.writeList(excludePatterns)
            args += ["-X", excludeFile!.path]
        }
        for s in substitutions { args += ["-s", s] }
        args.append("@" + archive.path)
        if let stage { args += ["-C", stage.root.path] + stage.items }

        let monitor = TransferMonitorBox()
        defer { monitor.cancel() }
        let r = try await ProcessRunner.run(tool, args,
                                            environment: ["COPYFILE_DISABLE": "1"],
                                            onStart: { pid in
                                                if !monitorRoots.isEmpty {
                                                    monitor.set(TransferMonitor.start(pid: pid, roots: monitorRoots, tracker: tracker))
                                                }
                                            }) { data in
            tracker?.feed(data)
            return Self.passphraseWatcher(data)
        }
        monitor.cancel()
        tracker?.finish()
        // Şifreli girdi + parola yok: bsdtar sonsuza dek "Enter passphrase" yazar; görür görmez kesilir ve parola istenir.
        if r.killedEarly || Self.mentionsPassphrase(r.text) { throw ArchiveError.passwordRequired }
        let report = try Self.interpretTar(r)
        try Self.replace(archive, with: tmp)
        return report
    }

    // MARK: Parolalı: aç, değiştir, aynı parolayla paketle

    private func rebuildEncryptedZip(archive: URL, password: String, tracker: ProgressTracker?,
                                     sources: [URL], monitorRoots: [String] = [],
                                     mutate: (URL) throws -> Void) async throws -> OperationReport {
        guard let tool = tools.bsdtar else { throw ArchiveError.toolMissing("bsdtar") }
        let fm = FileManager.default
        let work = Self.temporaryRoot.appendingPathComponent("edit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let tmp = archive.deletingLastPathComponent()
            .appendingPathComponent(".\(archive.lastPathComponent).macrar-\(UUID().uuidString).tmp")
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: tmp)
        }

        // 1) Aç
        let ex = try await ProcessRunner.run(tool, ["-xf", archive.path, "-C", work.path, "--passphrase", password],
                                             environment: ["COPYFILE_DISABLE": "1"],
                                             exactArguments: [password], onOutput: Self.passphraseWatcher)
        if ex.killedEarly || Self.mentionsPassphrase(ex.text) { throw ArchiveError.wrongPassword }
        _ = try Self.interpretTar(ex)

        // 2) Değiştir
        try mutate(work)

        // 3) AES-256 ile yeniden paketle
        let top = try fm.contentsOfDirectory(atPath: work.path).sorted()
        var args = ["--format", "zip", "--options", "zip:encryption=aes256", "--passphrase", password, "-cvf", tmp.path, "-C", work.path]
        if top.isEmpty {
            // Boş arşiv: bsdtar en az bir girdi ister; boş ZIP'in sabit biçimini kendimiz yazarız.
            try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: tmp)
            try Self.replace(archive, with: tmp)
            return OperationReport()
        }
        args += top
        let monitor = TransferMonitorBox()
        defer { monitor.cancel() }
        let r = try await ProcessRunner.run(tool, args, environment: ["COPYFILE_DISABLE": "1"], exactArguments: [password],
                                            onStart: { pid in
                                                if !monitorRoots.isEmpty {
                                                    monitor.set(TransferMonitor.start(pid: pid, roots: monitorRoots + [work.path], tracker: tracker))
                                                }
                                            }) { data in
            tracker?.feed(data); return false
        }
        monitor.cancel()
        tracker?.finish()
        let report = try Self.interpretTar(r)
        try Self.replace(archive, with: tmp)
        return report
    }

    // MARK: Yardımcılar

    /// Arşivde şifreli girdi var ve parola verilmediyse `passwordRequired` fırlatır. AES şifreli ZIP'te dosya adları parolasız
    /// listelenebildiğinden arşiv "açık" görünür; ama düzenleme için parola gerekir.
    static func requirePasswordIfEncrypted(_ archive: URL, _ password: String?) throws {
        guard password == nil || password!.isEmpty else { return }
        if ZipCentralDirectory.read(archive).values.contains(where: \.encrypted) { throw ArchiveError.passwordRequired }
    }

    /// Geçici dosyayı asıl arşivin yerine koyar; izinleri korur.
    private static func replace(_ archive: URL, with tmp: URL) throws {
        let fm = FileManager.default
        if let perms = (try? fm.attributesOfItem(atPath: archive.path))?[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
        }
        _ = try fm.replaceItemAt(archive, withItemAt: tmp)
    }

    /// `macrar-new/<ad>` → kaynak sembolik bağlantıları (bsdtar `-H` ile izler).
    private static func makeStage(for sources: [URL]) throws -> ZipStage {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macrar-stage-\(UUID().uuidString)", isDirectory: true)
        let inner = root.appendingPathComponent(zipStageToken, isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        var items: [String] = []
        for src in sources {
            let name = src.lastPathComponent
            let link = inner.appendingPathComponent(name)
            if fm.fileExists(atPath: link.path) || (try? link.checkResourceIsReachable()) == true { continue } // aynı ad: ilki geçerli
            try fm.createSymbolicLink(at: link, withDestinationURL: src)
            items.append(zipStageToken + "/" + name)
        }
        return ZipStage(root: root, items: items)
    }

    /// Eklenecek kaynakların arşivdeki adları (klasörler sonda "/" ile), Unicode normalize edilmiş.
    static func incomingNames(for sources: [URL], prefix: String) -> Set<String> {
        let fm = FileManager.default
        let head = prefix.isEmpty ? "" : prefix + "/"
        var names = Set<String>()
        func add(_ s: String) { names.insert(s.precomposedStringWithCanonicalMapping) }
        for src in sources {
            let base = head + src.lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { add(base); continue }
            add(base + "/")
            guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { continue }
            for case let url as URL in en {
                let rel = url.pathComponents.suffix(en.level).joined(separator: "/")
                let d = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                add(base + "/" + rel + (d ? "/" : ""))
            }
        }
        return names
    }

    /// Klasörse içeriğini birleştirerek, dosyaysa üzerine yazarak kopyalar (sembolik bağlantılar bağlantı olarak kalır).
    static func mergeCopy(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let isLink = (try? src.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { return }
        if isDir.boolValue && !isLink {
            var dstIsDir: ObjCBool = false
            if fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir), !dstIsDir.boolValue {
                try fm.removeItem(at: dst)
            }
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for child in try fm.contentsOfDirectory(atPath: src.path) {
                try mergeCopy(src.appendingPathComponent(child), to: dst.appendingPathComponent(child))
            }
        } else {
            if (try? dst.checkResourceIsReachable()) == true || (try? dst.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
        }
    }

    /// bsdtar `-X` desenini (tam eşleşme) üretir: `^ad$`; `\ * ? [ ]` kaçırılır.
    static func globPattern(forEntryName raw: String) -> String {
        var out = "^"
        for ch in raw {
            if "\\*?[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out + "$"
    }

    /// POSIX temel düzenli ifadede (bsdtar `-s`) özel karakterleri kaçırır.
    static func regexEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\.[]*^$".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// `-s` değeri: `<sınırlayıcı>desen<sınırlayıcı>yerine<sınırlayıcı>S`. bsdtar'da yerine metnindeki `&` düz karakterdir
    /// (ölçüldü); `\` ise geri-başvuru/kaçış sayıldığından içeren adlar reddedilir. Sınırlayıcı, ikisinde de geçmeyen
    /// bir karakterden seçilir. `S`: sembolik bağlantı hedeflerine dokunma.
    static func substitution(from pattern: String, to replacement: String) throws -> String {
        guard !replacement.contains("\\") else {
            throw ArchiveError.unsupported(String(localized: "Ters eğik çizgi (\\) içeren adlar ZIP’te yeniden adlandırılamaz veya taşınamaz."))
        }
        guard let d = "|#%!@~;,:".first(where: { !pattern.contains($0) && !replacement.contains($0) }) else {
            throw ArchiveError.unsupported(String(localized: "Bu ad ZIP düzenleme için çok fazla özel karakter içeriyor."))
        }
        return "\(d)\(pattern)\(d)\(replacement)\(d)S"
    }
}

// MARK: - ZIP liste ayrıntıları (CRC, sıkıştırılmış boyut, yöntem, şifreli mi)

/// ZIP'in "merkezî dizin"ini doğrudan okur. bsdtar listesi CRC/sıkıştırılmış boyut vermez; `unzip -v` ise macOS'ta oluşan ayrışık
/// (NFD) Unicode adlarını bozar. Dosya içeriği okunmaz: yalnızca arşivin sonundaki dizin (zip64 dahil).
enum ZipCentralDirectory {
    struct Info: Equatable {
        var crc: UInt32?
        var packed: Int64
        var size: Int64
        var method: String
        var encrypted: Bool
    }

    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 { UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 }
    private static func u64(_ d: Data, _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }

    /// Ad (normalize edilmiş, sondaki "/" atılmış) → ayrıntı. Okunamayan/bozuk dizinde boş sözlük.
    static func read(_ url: URL) -> [String: Info] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? h.close() }
        guard let fileSize = try? h.seekToEnd(), fileSize >= 22 else { return [:] }

        // 1) Dosya sonundaki "end of central directory" kaydını bul (yorum en çok 65535 bayt).
        let tailLen = Int(min(fileSize, 65_557))
        try? h.seek(toOffset: fileSize - UInt64(tailLen))
        guard let tail = try? h.read(upToCount: tailLen), tail.count >= 22 else { return [:] }
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[tail.startIndex + i] == 0x50, u32(tail, i) == 0x0605_4B50, i + 22 + u16(tail, i + 20) == tail.count { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return [:] }
        var entryCount = UInt64(u16(tail, eocd + 10))
        var cdSize = UInt64(u32(tail, eocd + 12))
        var cdOffset = UInt64(u32(tail, eocd + 16))

        // 2) zip64: konum kaydı EOCD'nin hemen öncesindedir.
        if (entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF), eocd >= 20,
           u32(tail, eocd - 20) == 0x0706_4B50 {
            let z64Offset = u64(tail, eocd - 20 + 8)
            try? h.seek(toOffset: z64Offset)
            guard let z = try? h.read(upToCount: 56), z.count >= 56, u32(z, 0) == 0x0606_4B50 else { return [:] }
            entryCount = u64(z, 32); cdSize = u64(z, 40); cdOffset = u64(z, 48)
        }
        guard cdSize > 0, cdSize <= 512 * 1024 * 1024, cdOffset + cdSize <= fileSize else { return [:] }

        // 3) Merkezî dizin kayıtları
        try? h.seek(toOffset: cdOffset)
        guard let cd = try? h.read(upToCount: Int(cdSize)), cd.count == Int(cdSize) else { return [:] }
        var out: [String: Info] = [:]
        var p = 0
        var seen: UInt64 = 0
        while p + 46 <= cd.count, u32(cd, p) == 0x0201_4B50, seen < entryCount {
            seen += 1
            let flags = u16(cd, p + 8)
            let methodCode = u16(cd, p + 10)
            let crc = u32(cd, p + 16)
            var csize = UInt64(u32(cd, p + 20)), usize = UInt64(u32(cd, p + 24))
            let nameLen = u16(cd, p + 28), extraLen = u16(cd, p + 30), commentLen = u16(cd, p + 32)
            let next = p + 46 + nameLen + extraLen + commentLen
            guard next <= cd.count else { break }
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen))
            let extra = cd.subdata(in: (cd.startIndex + p + 46 + nameLen)..<(cd.startIndex + p + 46 + nameLen + extraLen))

            // Ek alanlar: 0x0001 zip64 boyutları, 0x9901 WinZip AES
            var aesVersion: Int?, realMethod = methodCode
            var q = 0
            while q + 4 <= extra.count {
                let id = u16(extra, q), len = u16(extra, q + 2)
                guard q + 4 + len <= extra.count else { break }
                let body = q + 4
                if id == 0x0001 {
                    var o = body
                    if usize == 0xFFFF_FFFF, o + 8 <= body + len { usize = u64(extra, o); o += 8 }
                    if csize == 0xFFFF_FFFF, o + 8 <= body + len { csize = u64(extra, o); o += 8 }
                } else if id == 0x9901, len >= 7 {
                    aesVersion = u16(extra, body)
                    realMethod = u16(extra, body + 5)
                }
                q += 4 + len
            }

            var name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            if flags & 0x800 == 0, String(data: nameData, encoding: .utf8) == nil { name = String(data: nameData, encoding: .isoLatin1) ?? name }
            while name.hasPrefix("./") { name.removeFirst(2) }
            let isDir = name.hasSuffix("/")
            while name.hasSuffix("/") { name.removeLast() }
            if !name.isEmpty, !isDir {
                // AE-2 arşivlerinde CRC alanı 0'dır (gerçek değer yok): bilinmiyor say.
                let crcKnown = !(methodCode == 99 && aesVersion == 2)
                var method = methodName(realMethod)
                if methodCode == 99 { method = "AES+" + method }
                out[name.precomposedStringWithCanonicalMapping] = Info(
                    crc: crcKnown ? crc : nil, packed: Int64(truncatingIfNeeded: csize), size: Int64(truncatingIfNeeded: usize),
                    method: method, encrypted: flags & 1 != 0)
            }
            p = next
        }
        return out
    }

    static func methodName(_ code: Int) -> String {
        switch code {
        case 0: return "Stored"
        case 8: return "Deflate"
        case 9: return "Deflate64"
        case 12: return "BZip2"
        case 14: return "LZMA"
        case 93: return "Zstd"
        case 95: return "XZ"
        default: return String(localized: "Yöntem \(code)")
        }
    }
}

extension ArchiveService {
    /// bsdtar listesine CRC, sıkıştırılmış boyut, yöntem ve şifreli bilgisini ekler. Dizin okunamazsa girdiler olduğu gibi döner.
    static func addingZipDetails(to entries: [ArchiveEntry], archive: URL) async -> [ArchiveEntry] {
        guard isZIP(archive) else { return entries }
        let details = await Task.detached { ZipCentralDirectory.read(archive) }.value
        guard !details.isEmpty else { return entries }
        return entries.map { e in
            guard !e.isDirectory, let d = details[e.path.precomposedStringWithCanonicalMapping] else { return e }
            var e = e
            e.crc32 = d.crc.map { String(format: "%08X", $0) }
            e.packedSize = d.packed
            e.method = d.method
            e.isEncrypted = d.encrypted
            return e
        }
    }
}
