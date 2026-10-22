import XCTest
import MacRARCore
@testable import MacRAR

/// Açık ZIP arşivinde ekleme / silme / yeniden adlandırma: arayüz mantığı (AppModel). Yalnızca bsdtar gerekir (rar gerekmez).
@MainActor
final class ZipEditingModelTests: XCTestCase {
    var tmp: URL!
    var model: AppModel { AppModel.shared }
    let fm = FileManager.default

    override func setUp() async throws {
        var tools = TestTools.paths()
        try XCTSkipUnless(tools.bsdtar != nil, "bsdtar yok")
        tools.rar = nil          // rar yokmuş gibi: ZIP düzenleme onsuz çalışmalı
        tools.unrar = nil
        model.tools = tools
        tmp = fm.temporaryDirectory.appendingPathComponent("macrar-zipui-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
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
        model.closeArchive()
        if let tmp { try? fm.removeItem(at: tmp) }
    }

    func makeZip(password: String? = nil) async throws -> URL {
        let src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src.appendingPathComponent("klasör"), withIntermediateDirectories: true)
        try "kök".write(to: src.appendingPathComponent("kök.txt"), atomically: true, encoding: .utf8)
        try "iç".write(to: src.appendingPathComponent("klasör/iç.txt"), atomically: true, encoding: .utf8)
        let archive = tmp.appendingPathComponent("a.zip")
        var o = CompressOptions(archive: archive, sources: try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))
        o.format = .zip
        o.password = password
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

    func row(_ name: String) throws -> Row { try XCTUnwrap(model.rows.first { $0.name == name }, "satır yok: \(name)") }

    func testZipIsEditableWithoutRarTool() async throws {
        let zip = try await makeZip()
        XCTAssertFalse(model.tools.canWriteRAR)
        await model.loadArchive(zip)
        XCTAssertTrue(model.isZipArchive)
        XCTAssertTrue(model.canModifyArchive)
        XCTAssertTrue(model.canAdd)
        XCTAssertFalse(model.canEditRARFeatures, "yorum / kurtarma kaydı / kilit yalnızca RAR")
        model.selection = [try row("kök.txt").id]
        XCTAssertTrue(model.canDelete)
    }

    func testNonZipLibarchiveStaysReadOnly() async throws {
        let tar = tmp.appendingPathComponent("a.tar.gz")
        let src = tmp.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "x".write(to: src.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        var o = CompressOptions(archive: tar, sources: [src.appendingPathComponent("x.txt")])
        o.format = .tarGz
        try await model.service.add(o)
        await model.loadArchive(tar)
        XCTAssertTrue(model.isInArchive)
        XCTAssertFalse(model.isZipArchive)
        XCTAssertFalse(model.canModifyArchive)
        XCTAssertFalse(model.canAdd)
    }

    func testDropOnOpenZipOpensAddSheetForThatArchive() async throws {
        let zip = try await makeZip()
        await model.loadArchive(zip)
        let f = tmp.appendingPathComponent("yeni.txt")
        try "y".write(to: f, atomically: true, encoding: .utf8)
        model.handleDrop([f])
        guard case .add(let req)? = model.sheet else { return XCTFail("Ekle penceresi açılmadı: \(String(describing: model.sheet)) \(String(describing: model.alert?.message))") }
        XCTAssertEqual(req.existingArchive, zip)
        XCTAssertNil(model.alert)
    }

    func testAddThroughModelUpdatesListing() async throws {
        let zip = try await makeZip()
        await model.loadArchive(zip)
        model.enterArchivePath("klasör")
        let f = tmp.appendingPathComponent("yeni.txt")
        try "y".write(to: f, atomically: true, encoding: .utf8)
        model.openAddSheet(sources: [f])
        guard case .add(let req)? = model.sheet else { return XCTFail("Ekle penceresi açılmadı") }
        XCTAssertEqual(req.pathInArchive, "klasör")
        var o = CompressOptions(archive: zip, sources: req.sources)
        o.format = .zip
        o.appendToExisting = true
        o.pathInArchive = req.pathInArchive
        let ok = await model.runAdd(o)
        XCTAssertTrue(ok)
        XCTAssertEqual(Set(model.rows.map(\.name)), ["iç.txt", "yeni.txt"])
        XCTAssertEqual(model.listing?.entries.filter { $0.path == "kök.txt" }.count, 1)
    }

    func testDeleteThroughModel() async throws {
        let zip = try await makeZip()
        await model.loadArchive(zip)
        model.selection = [try row("klasör").id]
        model.confirmDelete()
        let alert = try XCTUnwrap(model.alert)
        let confirm = try XCTUnwrap(alert.confirm)
        confirm.action()
        try await waitUntil("silme") { !(AppModel.shared.listing?.entries.contains { $0.path.hasPrefix("klasör") } ?? true) }
        XCTAssertEqual(model.rows.map(\.name), ["kök.txt"])
    }

    func testRenameThroughModel() async throws {
        let zip = try await makeZip()
        await model.loadArchive(zip)
        model.selection = [try row("klasör").id]
        model.promptRename()
        guard case .prompt(let req)? = model.sheet else { return XCTFail("Ad sorusu açılmadı") }
        req.onConfirm("dizin")
        try await waitUntil("yeniden adlandırma") { AppModel.shared.listing?.entries.contains { $0.path == "dizin/iç.txt" } ?? false }
        XCTAssertEqual(Set(model.rows.map(\.name)), ["dizin", "kök.txt"])
    }

    func testEncryptedZipEditsUseOpenArchivePassword() async throws {
        let zip = try await makeZip(password: "gizli ş")
        let (l, pw) = (try await model.service.list(archive: zip, password: "gizli ş"), "gizli ş")
        model.archiveURL = zip
        model.listing = l
        model.archivePassword = pw
        // loadArchive parola sormadan açabilsin diye durumu elle kurduk; ZIP bayrağı için yeniden yükle
        await model.loadArchive(zip)
        if model.archivePassword == nil { model.archivePassword = pw }
        let f = tmp.appendingPathComponent("yeni.txt")
        try "y".write(to: f, atomically: true, encoding: .utf8)
        var o = CompressOptions(archive: zip, sources: [f])
        o.format = .zip
        o.appendToExisting = true
        o.password = model.archivePassword
        _ = await model.runAdd(o)
        let after = try await model.service.list(archive: zip, password: "gizli ş").entries.map(\.path)
        XCTAssertTrue(after.contains("yeni.txt"), "\(after)")
    }

    func waitForPasswordSheet(different old: UUID? = nil) async throws -> PasswordRequest {
        for _ in 0..<200 {
            if case .password(let r)? = model.sheet, r.id != old { return r }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("parola penceresi açılmadı")
    }

    /// Hata raporu (GUI): parolalı ZIP parolasız listelenir; Ekle parolayı sormalı, yanlış parolada yeniden sormalı.
    func testAddToEncryptedZipAsksPasswordRetriesAndRemembersIt() async throws {
        let zip = try await makeZip(password: "doğru ş")
        await model.loadArchive(zip)
        XCTAssertTrue(model.isInArchive)
        XCTAssertNil(model.archivePassword, "AES ZIP adları parolasız listelenir: açılışta parola sorulmaz")

        let f = tmp.appendingPathComponent("yeni.txt")
        try "y".write(to: f, atomically: true, encoding: .utf8)
        var o = CompressOptions(archive: zip, sources: [f])
        o.format = .zip
        o.appendToExisting = true
        let task = Task { await model.runAdd(o) }

        let first = try await waitForPasswordSheet()
        XCTAssertFalse(first.wrong)
        first.resolve("yanlış")
        let second = try await waitForPasswordSheet(different: first.id)
        XCTAssertTrue(second.wrong)
        second.resolve("doğru ş")
        let ok = await task.value

        XCTAssertTrue(ok)
        XCTAssertNil(model.operation, "hata katmanı kalmamalı")
        XCTAssertEqual(model.archivePassword, "doğru ş", "oturum için hatırlanmalı")
        let paths = try await model.service.list(archive: zip, password: "doğru ş").entries.map(\.path)
        XCTAssertTrue(paths.contains("yeni.txt"), "\(paths)")
        XCTAssertTrue(paths.contains("kök.txt"))
    }

    func testAddToEncryptedZipCancelledPasswordLeavesArchiveUntouched() async throws {
        let zip = try await makeZip(password: "p")
        let before = try Data(contentsOf: zip)
        await model.loadArchive(zip)
        let f = tmp.appendingPathComponent("yeni.txt")
        try "y".write(to: f, atomically: true, encoding: .utf8)
        var o = CompressOptions(archive: zip, sources: [f])
        o.format = .zip
        o.appendToExisting = true
        let task = Task { await model.runAdd(o) }
        let req = try await waitForPasswordSheet()
        req.resolve(nil)
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertNil(model.operation)
        XCTAssertEqual(try Data(contentsOf: zip), before)
    }

    func testDeleteFromEncryptedZipAsksPassword() async throws {
        let zip = try await makeZip(password: "p")
        await model.loadArchive(zip)
        model.selection = [try row("kök.txt").id]
        model.confirmDelete()
        try XCTUnwrap(model.alert?.confirm).action()
        let req = try await waitForPasswordSheet()
        req.resolve("p")
        try await waitUntil("silme") { !(AppModel.shared.listing?.entries.contains { $0.path == "kök.txt" } ?? true) }
    }
}
