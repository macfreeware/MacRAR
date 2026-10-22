import XCTest
@testable import MacRARCore

/// Gerçek rar/unrar/bsdtar ile uçtan uca testler. Araçlar yoksa atlanır.
final class IntegrationTests: XCTestCase {
    var tmp: URL!
    var service: ArchiveService!
    var tools: ToolPaths!

    override func setUpWithError() throws {
        tools = TestTools.paths()
        service = ArchiveService(tools: tools)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// tmp/src/{kök.txt, klasör/türkçe dosya.txt, klasör/alt/data.bin}
    @discardableResult
    func makeSource() throws -> URL {
        let src = tmp.appendingPathComponent("src", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("klasör/alt"), withIntermediateDirectories: true)
        try "merhaba".write(to: src.appendingPathComponent("kök.txt"), atomically: true, encoding: .utf8)
        try "türkçe içerik".write(to: src.appendingPathComponent("klasör/türkçe dosya.txt"), atomically: true, encoding: .utf8)
        try Data((0..<200_000).map { UInt8($0 % 251) }).write(to: src.appendingPathComponent("klasör/alt/data.bin"))
        return src
    }

    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    // MARK: RAR

    func testRarRoundTripWithUnicodeNames() async throws {
        try XCTSkipUnless(tools.canWriteRAR && tools.canReadRAR, "rar/unrar yok")
        let src = try makeSource()
        let archive = tmp.appendingPathComponent("test.rar")

        var opts = CompressOptions(archive: archive, sources: [src])
        opts.method = .good
        let tracker = await ProgressTracker.forAdding(opts)
        try await service.add(opts, tracker: tracker)
        XCTAssertEqual(tracker.drain().fraction ?? 0, 1.0, accuracy: 0.01)

        let listing = try await service.list(archive: archive)
        XCTAssertEqual(listing.engine, .rar)
        let paths = Set(listing.entries.map { $0.path })
        XCTAssertTrue(paths.contains("src/klasör/türkçe dosya.txt"), "\(paths)")
        XCTAssertTrue(paths.contains("src/klasör"))
        XCTAssertEqual(listing.fileCount, 3)

        // Hepsini çıkar
        let out = tmp.appendingPathComponent("out-all")
        try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out))
        XCTAssertEqual(try read(out.appendingPathComponent("src/klasör/alt/data.bin")),
                       try read(src.appendingPathComponent("klasör/alt/data.bin")))

        // Sadece bir klasörü seç → içeriğiyle gelmeli, diğerleri gelmemeli
        let out2 = tmp.appendingPathComponent("out-sel")
        let sel = listing.entries.filter { $0.path == "src/klasör" }
        let eTracker = ProgressTracker.forExtraction(entries: ArchiveSelection.expand(sel, in: listing.entries),
                                                     destination: out2, flatten: false, engine: .rar)
        try await service.extract(archive: archive, selection: sel, options: ExtractOptions(destination: out2),
                                  tracker: eTracker)
        XCTAssertEqual(eTracker.drain().fraction ?? 0, 1.0, accuracy: 0.01)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out2.appendingPathComponent("src/klasör/türkçe dosya.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out2.appendingPathComponent("src/kök.txt").path))

        // Yolsuz çıkarma
        let out3 = tmp.appendingPathComponent("out-flat")
        try await service.extract(archive: archive, selection: nil,
                                  options: ExtractOptions(destination: out3, keepPaths: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out3.appendingPathComponent("data.bin").path))

        // Sınama
        try await service.test(archive: archive)
    }

    func testRarPasswordAndEncryptedHeaders() async throws {
        try XCTSkipUnless(tools.canWriteRAR && tools.canReadRAR, "rar/unrar yok")
        let src = try makeSource()

        for encryptNames in [false, true] {
            let archive = tmp.appendingPathComponent("pw-\(encryptNames).rar")
            var opts = CompressOptions(archive: archive, sources: [src])
            opts.password = "gizli şifre 123"
            opts.encryptNames = encryptNames
            try await service.add(opts)

            if encryptNames {
                do { _ = try await service.list(archive: archive); XCTFail("parolasız listelenmemeli") }
                catch ArchiveError.passwordRequired {}
                do { _ = try await service.list(archive: archive, password: "yanlis"); XCTFail() }
                catch ArchiveError.wrongPassword {}
            }
            let listing = try await service.list(archive: archive, password: "gizli şifre 123")
            XCTAssertEqual(listing.fileCount, 3)
            XCTAssertTrue(listing.hasEncryptedFiles)

            let out = tmp.appendingPathComponent("pw-out-\(encryptNames)")
            do {
                try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out))
                XCTFail("parolasız çıkarılmamalı")
            } catch ArchiveError.passwordRequired {}
            do {
                try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out),
                                          password: "yanlis")
                XCTFail("yanlış parola ile çıkarılmamalı")
            } catch ArchiveError.wrongPassword {}
            try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out),
                                      password: "gizli şifre 123")
            XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("src/kök.txt"), encoding: .utf8), "merhaba")
        }
    }

    func testRarDeleteRenameCommentRecoveryAndPreview() async throws {
        try XCTSkipUnless(tools.canWriteRAR && tools.canReadRAR, "rar/unrar yok")
        let src = try makeSource()
        let archive = tmp.appendingPathComponent("edit.rar")
        try await service.add(CompressOptions(archive: archive, sources: [src]))

        var listing = try await service.list(archive: archive)
        // Klasörü sil (içerikle birlikte)
        let folder = listing.entries.first { $0.path == "src/klasör" }!
        try await service.delete(from: archive, entries: [folder])
        listing = try await service.list(archive: archive)
        XCTAssertEqual(listing.entries.filter { $0.path.hasPrefix("src/klasör") }.count, 0)

        // Yeniden adlandır
        let file = listing.entries.first { $0.path == "src/kök.txt" }!
        try await service.rename(in: archive, entry: file, newPath: "src/yeni ad.txt")
        listing = try await service.list(archive: archive)
        XCTAssertTrue(listing.entries.contains { $0.path == "src/yeni ad.txt" })

        // Önizleme için geçici çıkarma
        let entry = listing.entries.first { $0.path == "src/yeni ad.txt" }!
        let preview = try await service.extractForPreview(archive: archive, entry: entry)
        XCTAssertEqual(try String(contentsOf: preview, encoding: .utf8), "merhaba")
        ArchiveService.cleanTemporaryFiles()

        // Yorum + kurtarma kaydı
        try await service.setComment(archive: archive, comment: "Merhaba yorum")
        try await service.addRecoveryRecord(archive: archive, percent: 3)
        listing = try await service.list(archive: archive)
        XCTAssertEqual(listing.info.comment, "Merhaba yorum")
        XCTAssertTrue(listing.info.hasRecoveryRecord)
    }

    func testRarVolumesAndOptions() async throws {
        try XCTSkipUnless(tools.canWriteRAR && tools.canReadRAR, "rar/unrar yok")
        let src = try makeSource()
        let archive = tmp.appendingPathComponent("vol.rar")
        var opts = CompressOptions(archive: archive, sources: [src])
        opts.method = .store
        opts.volumeSize = "50k"
        opts.solid = true
        opts.recoveryPercent = 2
        opts.pathInArchive = "ekler/alt"
        try await service.add(opts)
        let first = tmp.appendingPathComponent("vol.part1.rar")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        let listing = try await service.list(archive: first)
        XCTAssertTrue(listing.entries.contains { $0.path == "ekler/alt/src/kök.txt" }, "\(listing.entries.map { $0.path })")
        XCTAssertTrue(listing.info.isVolume)
    }

    // MARK: libarchive (zip / 7z / tar.gz)

    func testLibarchiveFormatsRoundTrip() async throws {
        try XCTSkipUnless(tools.bsdtar != nil, "bsdtar yok")
        let src = try makeSource()

        for fmt in [ArchiveFormat.zip, .sevenZip, .tarGz, .tarBz2] {
            let archive = tmp.appendingPathComponent("a-\(fmt.rawValue).\(fmt.fileExtension)")
            var opts = CompressOptions(archive: archive, sources: [src])
            opts.format = fmt
            let tracker = await ProgressTracker.forAdding(opts)
            try await service.add(opts, tracker: tracker)

            let listing = try await service.list(archive: archive)
            XCTAssertEqual(listing.engine, .libarchive)
            XCTAssertTrue(listing.entries.contains { $0.path == "src/klasör/türkçe dosya.txt" },
                          "\(fmt): \(listing.entries.map { $0.path })")
            // Bütün arşiv
            let out = tmp.appendingPathComponent("out-\(fmt.rawValue)")
            try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out))
            XCTAssertEqual(try read(out.appendingPathComponent("src/klasör/alt/data.bin")).count, 200_000)

            // Seçili klasör (listeden gelen ham adla)
            let sel = listing.entries.filter { $0.path == "src/klasör" }
            XCTAssertEqual(sel.count, 1)
            let out2 = tmp.appendingPathComponent("outsel-\(fmt.rawValue)")
            let expanded = ArchiveSelection.expand(sel, in: listing.entries)
            try await service.extract(archive: archive, selection: expanded, options: ExtractOptions(destination: out2))
            XCTAssertTrue(FileManager.default.fileExists(atPath: out2.appendingPathComponent("src/klasör/türkçe dosya.txt").path), "\(fmt)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out2.appendingPathComponent("src/kök.txt").path), "\(fmt)")
        }
    }

    func testZipWithPassword() async throws {
        try XCTSkipUnless(tools.bsdtar != nil, "bsdtar yok")
        let src = try makeSource()
        let archive = tmp.appendingPathComponent("pw.zip")
        var opts = CompressOptions(archive: archive, sources: [src])
        opts.format = .zip
        opts.password = "abc123"
        try await service.add(opts)

        let out = tmp.appendingPathComponent("zout")
        do {
            try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out))
            XCTFail("parolasız çıkarılmamalı")
        } catch ArchiveError.passwordRequired {}
        do {
            try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out), password: "bad")
            XCTFail("yanlış parola")
        } catch ArchiveError.wrongPassword {}
        try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out), password: "abc123")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("src/kök.txt"), encoding: .utf8), "merhaba")
    }

    // MARK: Parolalarda Unicode (komut satırı argümanları)

    /// Foundation argümanları NFD'ye çevirir ("ş" → "s" + çengel); parola gibi argümanlar baytı baytına gitmeli.
    func testExactArgumentsPreserveNFCBytesWhileDefaultDoesNot() async throws {
        let password = "gizli şifre 'ğ' çÇ"
        let printf = URL(fileURLWithPath: "/usr/bin/printf")
        let normal = try await ProcessRunner.run(printf, ["%s", password])
        let exact = try await ProcessRunner.run(printf, ["%s", password], exactArguments: [password])
        XCTAssertEqual(exact.output, Data(password.utf8), "exactArguments baytı baytına (NFC) iletmeli")
        XCTAssertNotEqual(normal.output, Data(password.utf8), "varsayılan yol NFD'ye çeviriyor (bu, düzeltmenin gerekçesi)")
        // ASCII argümanlar ve boşluk/tırnak içerenler bozulmamalı
        let mixed = try await ProcessRunner.run(printf, ["%s|%s|%s", "a b", "it's", "ç"], exactArguments: ["ç"])
        XCTAssertEqual(String(decoding: mixed.output, as: UTF8.self), "a b|it's|ç")
    }

    /// ZIP'te Türkçe karakterli parola: MacRAR'ın oluşturduğu başka yerde, başkasının oluşturduğu MacRAR'da açılmalı.
    func testZipTurkishPasswordInteroperatesWithExternalBytes() async throws {
        try XCTSkipUnless(tools.bsdtar != nil, "bsdtar yok")
        let pw = "şifre-ğüİ 1"
        let src = try makeSource()

        // 1) MacRAR oluşturur → bağımsız (ham bayt) bir komutla açılır
        let zip = tmp.appendingPathComponent("tr.zip")
        var o = CompressOptions(archive: zip, sources: [src]); o.format = .zip; o.password = pw
        try await service.add(o)
        let octal = pw.utf8.map { String(format: "\\%03o", $0) }.joined()
        let out1 = tmp.appendingPathComponent("ext1"); try FileManager.default.createDirectory(at: out1, withIntermediateDirectories: true)
        let sh = Process(); sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "/usr/bin/bsdtar -xf '\(zip.path)' -C '\(out1.path)' --passphrase \"$(printf '\(octal)')\" 2>/dev/null"]
        try sh.run(); sh.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: out1.appendingPathComponent("src/kök.txt"), encoding: .utf8), "merhaba",
                       "MacRAR'ın ZIP'i, parola NFC baytlarıyla başka bir araçta açılmalı")

        // 2) Başka bir araç (ham bayt NFC parola) oluşturur → MacRAR açar
        let zip2 = tmp.appendingPathComponent("ext.zip")
        let sh2 = Process(); sh2.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh2.arguments = ["-c", "cd '\(tmp.path)' && /usr/bin/bsdtar --format zip --options zip:encryption=aes256 --passphrase \"$(printf '\(octal)')\" -cf '\(zip2.path)' src 2>/dev/null"]
        try sh2.run(); sh2.waitUntilExit()
        let out2 = tmp.appendingPathComponent("ext2")
        try await service.extract(archive: zip2, selection: nil, options: ExtractOptions(destination: out2), password: pw)
        XCTAssertEqual(try String(contentsOf: out2.appendingPathComponent("src/kök.txt"), encoding: .utf8), "merhaba",
                       "başka araçta oluşturulan ZIP'in Türkçe parolası MacRAR'da tutmalı")
    }

    func testCancellationTerminatesProcess() async throws {
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("iptal edilmeliydi") } catch ArchiveError.cancelled {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
