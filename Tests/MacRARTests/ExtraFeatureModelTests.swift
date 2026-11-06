import XCTest
import MacRARCore
@testable import MacRAR

/// Toplu sınama, birleştirme, karşılaştırma ve parola ipucu: arayüz mantığı (AppModel). Yalnızca bsdtar gerekir.
@MainActor
final class ExtraFeatureModelTests: XCTestCase {
    var tmp: URL!
    var model: AppModel { AppModel.shared }
    let fm = FileManager.default

    override func setUp() async throws {
        var tools = TestTools.paths()
        try XCTSkipUnless(tools.bsdtar != nil, "bsdtar yok")
        tools.rar = nil
        tools.unrar = nil
        model.tools = tools
        tmp = fm.temporaryDirectory.appendingPathComponent("macrar-extra-ui-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        model.closeArchive()
        model.sheet = nil
        model.operation = nil
        model.alert = nil
        model.vault = PasswordVault(store: InMemoryPasswordStore())
        model.endQuickSessionTakeover()
        model.onQuickSessionEnd = {}
        model.hasVisibleWindow = { false }
        SheetPanel.isEnabled = false
    }

    override func tearDown() async throws {
        model.sheet = nil
        model.alert = nil
        model.closeArchive()
        if let tmp { try? fm.removeItem(at: tmp) }
    }

    @discardableResult
    func makeZip(_ name: String, _ files: [String: String]) async throws -> URL {
        let src = tmp.appendingPathComponent("src-\(name)")
        for (rel, text) in files {
            let u = src.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let archive = tmp.appendingPathComponent(name)
        var o = CompressOptions(archive: archive, sources: try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))
        o.format = .zip
        try await model.service.add(o)
        return archive
    }

    func waitUntil(_ what: String, timeout: Double = 10, _ cond: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return XCTFail("zaman aşımı: \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Klasörü açar ve verilen adlı satırları seçer (görünüm sırası: ada göre).
    func openFolderSelecting(_ names: [String]) async throws {
        model.openFolder(tmp)
        // Önceki testten kalan satırlar (aynı adlı dosyalar) sayılmasın: satırlar BU testin klasöründen olmalı.
        let here = tmp.resolvingSymlinksInPath().path
        try await waitUntil("klasör listesi") {
            let mine = AppModel.shared.rows.filter { $0.url?.deletingLastPathComponent().resolvingSymlinksInPath().path == here }
            return Set(mine.map(\.name)).isSuperset(of: names)
        }
        model.selection = Set(model.rows.filter { names.contains($0.name) }.map(\.id))
        XCTAssertEqual(model.selection.count, names.count)
    }

    func testGatingForMergeCompareAndTest() async throws {
        try await makeZip("a.zip", ["x.txt": "1"])
        try await makeZip("b.zip", ["y.txt": "2"])
        try await makeZip("c.zip", ["z.txt": "3"])
        try await openFolderSelecting(["a.zip"])
        XCTAssertTrue(model.canTest); XCTAssertFalse(model.canMerge); XCTAssertFalse(model.canCompare)
        try await openFolderSelecting(["a.zip", "b.zip"])
        XCTAssertTrue(model.canTest); XCTAssertTrue(model.canMerge); XCTAssertTrue(model.canCompare)
        try await openFolderSelecting(["a.zip", "b.zip", "c.zip"])
        XCTAssertTrue(model.canMerge); XCTAssertFalse(model.canCompare)
        model.selection = []
        XCTAssertFalse(model.canTest); XCTAssertFalse(model.canMerge)
    }

    func testBatchTestSummarizesGoodAndBadArchives() async throws {
        let good = try await makeZip("iyi.zip", ["x.txt": String(repeating: "0123456789", count: 20_000)])
        _ = good
        let bad = try await makeZip("bozuk.zip", ["x.txt": String(repeating: "abcdefghij", count: 20_000)])
        var data = try Data(contentsOf: bad)
        data[data.count / 2] ^= 0xFF; data[data.count / 2 + 1] ^= 0xFF
        try data.write(to: bad)

        try await openFolderSelecting(["iyi.zip", "bozuk.zip"])
        await model.runTest()
        let alert = try XCTUnwrap(model.alert)
        XCTAssertEqual(alert.title, "Sınama: 1 arşivde sorun var", alert.message)
        XCTAssertTrue(alert.message.contains("✓ iyi.zip"), alert.message)
        XCTAssertTrue(alert.message.contains("✗ bozuk.zip"), alert.message)
        XCTAssertNil(model.operation, "hata katmanı takılı kalmamalı")
    }

    func testBatchTestAllGoodAndSingleArchiveFlow() async throws {
        try await makeZip("a.zip", ["x.txt": "1"])
        try await makeZip("b.zip", ["y.txt": "2"])
        try await openFolderSelecting(["a.zip", "b.zip"])
        await model.runTest()
        XCTAssertEqual(model.alert?.title, "Sınama tamamlandı")
        XCTAssertEqual(model.alert?.message.components(separatedBy: "\n").count, 2)

        model.alert = nil
        try await openFolderSelecting(["a.zip"])
        await model.runTest()
        XCTAssertEqual(model.alert?.title, "Sınama tamamlandı")
        XCTAssertTrue(model.alert?.message.contains("a.zip") ?? false)
    }

    func testTestInsideOpenZip() async throws {
        let zip = try await makeZip("a.zip", ["x.txt": "1"])
        await model.loadArchive(zip)
        XCTAssertTrue(model.canTest, "ZIP açıkken de Sına etkin olmalı")
        await model.runTest()
        XCTAssertEqual(model.alert?.title, "Sınama tamamlandı")
    }

    func testMergeWithConflictsAsksThenOpensAddSheetAndCleansUp() async throws {
        try await makeZip("a.zip", ["ortak.txt": "A", "sadece-a.txt": "a", "klasör/k.txt": "ka"])
        try await makeZip("b.zip", ["ortak.txt": "B", "sadece-b.txt": "b"])
        try await openFolderSelecting(["a.zip", "b.zip"])
        model.beginMerge()
        try await waitUntil("çakışma uyarısı") { AppModel.shared.alert != nil }
        let alert = try XCTUnwrap(model.alert)
        XCTAssertTrue(alert.title.contains("1 dosya"), alert.title)
        XCTAssertTrue(alert.message.contains("ortak.txt"))
        let confirm = try XCTUnwrap(alert.confirm)
        confirm.action()
        try await waitUntil("Ekle penceresi") { if case .add? = AppModel.shared.sheet { return true } else { return false } }
        guard case .add(let req)? = model.sheet else { return XCTFail() }
        XCTAssertEqual(req.defaultName, "Birleşik arşiv")
        XCTAssertNil(req.existingArchive, "birleştirme YENİ arşiv üretir")
        let staging = req.sources[0].deletingLastPathComponent()
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
        XCTAssertEqual(Set(req.sources.map(\.lastPathComponent)), ["ortak.txt", "sadece-a.txt", "sadece-b.txt", "klasör"])

        var o = CompressOptions(archive: tmp.appendingPathComponent("birlesik.zip"), sources: req.sources)
        o.format = .zip
        let ok = await model.runAdd(o)
        XCTAssertTrue(ok)
        let merged = try await model.service.list(archive: o.archive).entries.map(\.path)
        XCTAssertEqual(Set(merged), ["ortak.txt", "sadece-a.txt", "sadece-b.txt", "klasör", "klasör/k.txt"])
        // Çakışmada son arşivin (b.zip) dosyası kazanır
        let out = tmp.appendingPathComponent("out")
        try await model.service.extract(archive: o.archive, selection: nil, options: ExtractOptions(destination: out))
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("ortak.txt"), encoding: .utf8), "B")
        XCTAssertFalse(fm.fileExists(atPath: staging.path), "geçici birleştirme klasörü silinmeli")
    }

    func testMergeWithoutConflictsGoesStraightToAddSheet() async throws {
        try await makeZip("a.zip", ["a.txt": "A"])
        try await makeZip("b.zip", ["b.txt": "B"])
        try await openFolderSelecting(["a.zip", "b.zip"])
        model.beginMerge()
        try await waitUntil("Ekle penceresi") { if case .add? = AppModel.shared.sheet { return true } else { return false } }
        XCTAssertNil(model.alert)
    }

    func testCompareThroughModel() async throws {
        try await makeZip("a.zip", ["ortak.txt": "AAAA", "ayni.txt": "same", "sadece-a.txt": "a"])
        try await makeZip("b.zip", ["ortak.txt": "BBBB", "ayni.txt": "same", "sadece-b.txt": "b"])
        try await openFolderSelecting(["a.zip", "b.zip"])
        model.showCompare()
        try await waitUntil("karşılaştırma penceresi") { if case .compare? = AppModel.shared.sheet { return true } else { return false } }
        guard case .compare(let req)? = model.sheet else { return XCTFail() }
        XCTAssertEqual(req.firstName, "a.zip")
        XCTAssertEqual(req.secondName, "b.zip")
        func status(_ p: String) -> ArchiveComparison.Status? { req.result.items.first { $0.path == p }?.status }
        XCTAssertEqual(status("ortak.txt"), .differentContent)
        XCTAssertEqual(status("ayni.txt"), .identical)
        XCTAssertEqual(status("sadece-a.txt"), .onlyInFirst)
        XCTAssertEqual(status("sadece-b.txt"), .onlyInSecond)
    }

    func testPasswordHintIsSavedAndEdited() async throws {
        let vault = model.vault
        await vault.loadIfNeeded()
        await vault.add(name: "Muhasebe", password: "p1", hint: "  2024 arşivleri  ")
        await vault.add(name: "Notsuz", password: "p2")
        XCTAssertEqual(vault.items.first { $0.name == "Muhasebe" }?.hint, "2024 arşivleri", "baş/son boşluk kırpılır")
        XCTAssertNil(vault.items.first { $0.name == "Notsuz" }?.hint)
        var item = try XCTUnwrap(vault.items.first { $0.name == "Notsuz" })
        item.hint = "Yedek diski"
        await vault.update(item)
        XCTAssertEqual(vault.items.first { $0.name == "Notsuz" }?.hint, "Yedek diski")
    }

    // MARK: Güncelleme

    func testUpdateWaitsForWorkDialogsAndFinderSessions() async throws {
        XCTAssertTrue(model.isIdleForUpdate)

        // Gecikmeli işte `operation` ilk yarım saniye boştur; yine de iş sürüyor sayılır.
        let release = AsyncStream<Void>.makeStream()
        let work = Task {
            await model.perform("Deneme", tracker: ProgressTracker(), delayed: true) { for await _ in release.stream { break } }
        }
        while model.runningWork == 0 { await Task.yield() }
        XCTAssertNil(model.operation)
        XCTAssertFalse(model.isIdleForUpdate)
        release.continuation.finish()
        _ = await work.value
        model.operation = nil
        XCTAssertTrue(model.isIdleForUpdate)

        model.rarInstallProgress = "Başlatılıyor…"
        XCTAssertFalse(model.isIdleForUpdate)
        model.rarInstallProgress = nil

        model.alert = AlertInfo(title: "Başlık", message: "İleti")
        XCTAssertFalse(model.isIdleForUpdate)
        model.alert = nil

        model.beginQuickCommand()   // görünür pencere yok: Finder'dan başlatılan hızlı oturum
        XCTAssertFalse(model.isIdleForUpdate)
        model.endQuickSessionTakeover()
        XCTAssertTrue(model.isIdleForUpdate)
    }
}
