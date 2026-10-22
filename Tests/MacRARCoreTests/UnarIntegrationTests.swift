import XCTest
@testable import MacRARCore

/// rar/unrar YOKMUŞ gibi, RAR'ı yalnızca unar/lsar ile açma yolu. Gerçek araçlar yoksa atlanır.
/// (Arşivleri oluşturmak için `rar` gerekir; MACRAR_TEST_UNAR_DIR ile unar klasörü verilebilir.)
final class UnarIntegrationTests: XCTestCase {
    var tmp: URL!
    var creator: ArchiveService!   // rar ile arşiv üretir
    var service: ArchiveService!   // yalnızca unar kullanır

    override func setUpWithError() throws {
        let base = TestTools.paths()
        try XCTSkipUnless(base.canWriteRAR, "rar yok (test arşivleri üretilemiyor)")
        try XCTSkipUnless(base.canReadRARWithUnar, "unar/lsar yok")
        creator = ArchiveService(tools: base)
        var only = base; only.rar = nil; only.unrar = nil
        XCTAssertTrue(only.usesUnarForRAR)
        XCTAssertTrue(only.canReadRAR)
        service = ArchiveService(tools: only)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-unar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let tmp { try? FileManager.default.removeItem(at: tmp) } }

    @discardableResult
    func makeSource() throws -> URL {
        let src = tmp.appendingPathComponent("src", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("klasör/alt"), withIntermediateDirectories: true)
        try "merhaba".write(to: src.appendingPathComponent("kök.txt"), atomically: true, encoding: .utf8)
        try "türkçe içerik".write(to: src.appendingPathComponent("klasör/türkçe dosya.txt"), atomically: true, encoding: .utf8)
        try Data((0..<150_000).map { UInt8($0 % 251) }).write(to: src.appendingPathComponent("klasör/alt/data.bin"))
        return src
    }

    func makeArchive(_ name: String = "a.rar", password: String? = nil, encryptNames: Bool = false) async throws -> URL {
        let src = try makeSource()
        let archive = tmp.appendingPathComponent(name)
        var o = CompressOptions(archive: archive, sources: [src])
        o.password = password; o.encryptNames = encryptNames
        try await creator.add(o)
        return archive
    }

    func testListAndExtractAllWithUnicodeNames() async throws {
        let archive = try await makeArchive()
        let listing = try await service.list(archive: archive)
        XCTAssertEqual(listing.engine, .rar)
        let paths = Set(listing.entries.map(\.path))
        XCTAssertTrue(paths.contains("src/klasör/türkçe dosya.txt"), "\(paths)")
        XCTAssertTrue(paths.contains("src/klasör"))
        XCTAssertEqual(listing.fileCount, 3)
        XCTAssertTrue(listing.entries.allSatisfy { $0.index != nil }, "her girdinin sıra numarası olmalı")
        XCTAssertEqual(listing.entries.first { $0.path == "src/klasör/alt/data.bin" }?.size, 150_000)

        let out = tmp.appendingPathComponent("out")
        let tracker = ProgressTracker.forExtraction(entries: listing.entries, destination: out, flatten: false,
                                                    engine: .rar, style: service.progressStyle(for: .rar))
        try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out), tracker: tracker)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("src/klasör/alt/data.bin")).count, 150_000)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("src/klasör/türkçe dosya.txt"), encoding: .utf8), "türkçe içerik")
        XCTAssertEqual(tracker.drain().fraction ?? 0, 1.0, accuracy: 0.01, "ilerleme unar çıktısından hesaplanmalı")
    }

    func testExtractSelectionByIndexOnlyGetsThatFolder() async throws {
        let archive = try await makeArchive()
        let listing = try await service.list(archive: archive)
        let folder = listing.entries.filter { $0.path == "src/klasör" }
        let expanded = ArchiveSelection.expand(folder, in: listing.entries)
        XCTAssertGreaterThan(expanded.count, 1)
        let out = tmp.appendingPathComponent("sel")
        try await service.extract(archive: archive, selection: expanded, options: ExtractOptions(destination: out))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("src/klasör/alt/data.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("src/kök.txt").path), "seçilmeyen çıkarılmamalı")
    }

    func testOverwriteModes() async throws {
        let archive = try await makeArchive()
        let out = tmp.appendingPathComponent("ow")
        try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out))
        let f = out.appendingPathComponent("src/kök.txt")
        try "kullanıcı değişikliği".write(to: f, atomically: true, encoding: .utf8)

        try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out, overwrite: .skip))
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "kullanıcı değişikliği", "atla: dokunulmamalı")

        try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out, overwrite: .rename))
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "kullanıcı değişikliği", "yeniden adlandır: eski dosya korunmalı")
        // unar, çakışan KLASÖRÜN tamamını yeniden adlandırır (src → src-1) — unrar -or gibi tek tek dosyayı değil.
        let top = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertTrue(top.contains("src-1"), "tam kopya yanında (src-1) çıkmalı: \(top)")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("src-1/kök.txt"), encoding: .utf8), "merhaba")

        try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out, overwrite: .overwrite))
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "merhaba", "üzerine yaz: arşivdeki içerik gelmeli")
    }

    func testContentEncryptedPasswordFlow() async throws {
        let archive = try await makeArchive("pw.rar", password: "gizli şifre 1")
        let listing = try await service.list(archive: archive)       // başlıklar açık: parolasız listelenir
        XCTAssertTrue(listing.hasEncryptedFiles)
        let out = tmp.appendingPathComponent("pwout")
        do { try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out)); XCTFail("parolasız çıkmamalı") }
        catch ArchiveError.passwordRequired {}
        do { try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out), password: "yanlis"); XCTFail("yanlış parola") }
        catch ArchiveError.wrongPassword {}
        try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out), password: "gizli şifre 1")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("src/kök.txt"), encoding: .utf8), "merhaba")
    }

    func testHeaderEncryptedArchiveListsOnlyWithPassword() async throws {
        let archive = try await makeArchive("hp.rar", password: "sifre123", encryptNames: true)
        do { _ = try await service.list(archive: archive); XCTFail("parolasız listelenmemeli") } catch ArchiveError.passwordRequired {}
        do { _ = try await service.list(archive: archive, password: "yanlis"); XCTFail("yanlış parola") } catch ArchiveError.wrongPassword {}
        let listing = try await service.list(archive: archive, password: "sifre123")
        XCTAssertEqual(listing.fileCount, 3)
        let out = tmp.appendingPathComponent("hpout")
        try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out), password: "sifre123")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("src/klasör/alt/data.bin").path))
    }

    func testIntegrityTestDetectsCorruption() async throws {
        let archive = try await makeArchive()
        try await service.test(archive: archive)
        let broken = tmp.appendingPathComponent("broken.rar")
        let data = try Data(contentsOf: archive)
        try data.prefix(data.count / 3).write(to: broken)
        do { try await service.test(archive: broken); XCTFail("bozuk arşiv sınamadan geçmemeli") } catch ArchiveError.failed {} catch {
            // Bazı bozulmalarda arşiv hiç açılamaz (listeleme hatası da kabul)
            XCTAssertTrue("\(error)".count > 0)
        }
    }

    func testFlattenAndInvalidInputsAreReportedClearly() async throws {
        let archive = try await makeArchive()
        let out = tmp.appendingPathComponent("flat")
        do { try await service.extract(archive: archive, selection: nil, options: ExtractOptions(destination: out, keepPaths: false)); XCTFail("desteklenmiyor") }
        catch ArchiveError.unsupported(let m) { XCTAssertTrue(m.contains("unrar"), m) }
        let text = tmp.appendingPathComponent("düz.rar"); try "bu rar değil".write(to: text, atomically: true, encoding: .utf8)
        do { _ = try await service.list(archive: text); XCTFail("geçersiz dosya") } catch ArchiveError.failed {} // libarchive yolu da failed/boş verebilir
        catch {}
    }
}
