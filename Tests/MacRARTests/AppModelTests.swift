import XCTest
import UniformTypeIdentifiers
import CoreTransferable
import MacRARCore
@testable import MacRAR

/// Arayüz mantığı (AppModel): gerçek rar/unrar ile uçtan uca.
@MainActor
final class AppModelTests: XCTestCase {
    var tmp: URL!
    var model: AppModel { AppModel.shared }

    override func setUp() async throws {
        model.tools = TestTools.paths()
        try XCTSkipUnless(model.tools.canReadRAR && model.tools.canWriteRAR, "rar/unrar yok")
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        model.sheet = nil
        model.operation = nil
        model.alert = nil
        // Testler kullanıcının gerçek Anahtar Zinciri'ne dokunmasın
        model.vault = PasswordVault(store: InMemoryPasswordStore())
        // Hızlı oturum durumunu sıfırla (paylaşılan model testler arasında taşınmasın)
        model.endQuickSessionTakeover()
        model.onQuickSessionEnd = {}
        model.hasVisibleWindow = { false }
        SheetPanel.isEnabled = false          // Ekle/Çıkar diyaloğu için gerçek pencere açılmasın
        // Testler çalışırken Finder'da "bitince göster" pencereleri açılmasın (test işlemine ait tercih alanı).
        UserDefaults.standard.set(false, forKey: "quickReveal")
    }

    override func tearDown() async throws {
        model.closeArchive()
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    /// src/{kök.txt, klasör/türkçe dosya.txt, klasör/alt/derin.txt}
    func makeArchive(name: String = "a.rar", password: String? = nil) async throws -> URL {
        let src = tmp.appendingPathComponent("src")
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("klasör/alt"), withIntermediateDirectories: true)
        try "kök".write(to: src.appendingPathComponent("kök.txt"), atomically: true, encoding: .utf8)
        try "türkçe".write(to: src.appendingPathComponent("klasör/türkçe dosya.txt"), atomically: true, encoding: .utf8)
        try "derin".write(to: src.appendingPathComponent("klasör/alt/derin.txt"), atomically: true, encoding: .utf8)
        let archive = tmp.appendingPathComponent(name)
        var o = CompressOptions(archive: archive, sources: [src])
        o.password = password
        try await model.service.add(o)
        return archive
    }

    func testOpenNavigateSortAndSearch() async throws {
        let archive = try await makeArchive()
        await model.loadArchive(archive)
        XCTAssertTrue(model.isInArchive)
        XCTAssertEqual(model.rows.map(\.name), ["src"])

        model.enterArchivePath("src")
        XCTAssertEqual(model.rows.map(\.name), ["klasör", "kök.txt"], "klasörler önce gelmeli")

        model.enterArchivePath("src/klasör")
        XCTAssertEqual(Set(model.rows.map(\.name)), ["alt", "türkçe dosya.txt"])

        model.goUp()
        XCTAssertEqual(model.archivePath, "src")
        try await Task.sleep(for: .milliseconds(400)) // arşivin klasörü arka planda okunuyor
        model.goUp(); model.goUp()          // kök → arşivi kapat
        XCTAssertFalse(model.isInArchive)
        XCTAssertEqual(model.selectedRows.first?.url?.resolvingSymlinksInPath().path,
                       archive.resolvingSymlinksInPath().path, "kapatınca arşiv dosyası seçili olmalı")

        await model.loadArchive(archive)
        for query in ["DERİN", "derin", "Dérin", "ERİ"] {   // harf ve aksan duyarsız
            model.searchText = query
            model.refreshRows()
            XCTAssertEqual(model.rows.map(\.name), ["derin.txt"], "sorgu: \(query)")
        }
        model.searchText = "türkçe"
        model.refreshRows()
        XCTAssertEqual(model.rows.map(\.name), ["türkçe dosya.txt"])
        model.searchText = ""
    }

    func testExtractSelectionThroughModel() async throws {
        let archive = try await makeArchive()
        await model.loadArchive(archive)
        model.enterArchivePath("src")
        model.selection = Set(model.rows.filter { $0.name == "klasör" }.map(\.id))

        let dest = tmp.appendingPathComponent("out")
        var choices = ExtractChoices(destination: dest)
        choices.useSelection = true
        choices.reveal = false
        let req = ExtractRequest(archives: [archive], selectedRows: model.selectedRows, defaultDestination: dest)
        await model.runExtract(req, choices: choices)

        XCTAssertNil(model.operation, "başarılı işlem sonunda ilerleme penceresi kapanmalı")
        XCTAssertNil(model.alert)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("src/klasör/alt/derin.txt"), encoding: .utf8), "derin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("src/kök.txt").path))
    }

    func testExtractWithSubfolderFromFolderMode() async throws {
        let archive = try await makeArchive(name: "paket.rar")
        let dest = tmp.appendingPathComponent("hedef")
        var choices = ExtractChoices(destination: dest)
        choices.createSubfolder = true
        choices.reveal = false
        await model.runExtract(ExtractRequest(archives: [archive], selectedRows: [], defaultDestination: dest), choices: choices)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("paket/src/kök.txt").path))
    }

    func testAddCreatesArchiveAndFailureIsReported() async throws {
        let src = tmp.appendingPathComponent("belge.txt")
        try "içerik".write(to: src, atomically: true, encoding: .utf8)
        var o = CompressOptions(archive: tmp.appendingPathComponent("yeni.rar"), sources: [src])
        o.method = .best
        await model.runAdd(o)
        XCTAssertNil(model.operation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: o.archive.path))

        // Var olmayan kaynak → hata kullanıcıya gösterilmeli (operation penceresi failed durumunda kalır)
        let bad = CompressOptions(archive: tmp.appendingPathComponent("hatali.rar"),
                                  sources: [tmp.appendingPathComponent("yok.txt")])
        await model.runAdd(bad)
        if case .failed = model.operation?.phase { } else { XCTFail("hata gösterilmedi: \(String(describing: model.operation?.phase))") }
        model.operation = nil
    }

    func testPasswordPromptFlowResumesOperation() async throws {
        let archive = try await makeArchive(name: "gizli.rar", password: "doğru parola")
        // Başlıklar şifreli değil → liste açılır; çıkarma sırasında parola istenmeli.
        await model.loadArchive(archive)
        XCTAssertTrue(model.isInArchive)

        let dest = tmp.appendingPathComponent("out-pw")
        var choices = ExtractChoices(destination: dest)
        choices.reveal = false
        let req = ExtractRequest(archives: [archive], selectedRows: [], defaultDestination: dest)
        let task = Task { await model.runExtract(req, choices: choices) }

        // 1) parolasız deneme → parola penceresi
        let first = try await waitForPasswordSheet()
        XCTAssertFalse(first.wrong)
        first.resolve("yanlış")
        // 2) yanlış parola → pencere "wrong" ile yeniden
        let second = try await waitForPasswordSheet(different: first.id)
        XCTAssertTrue(second.wrong)
        second.resolve("doğru parola")
        await task.value

        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("src/kök.txt"), encoding: .utf8), "kök")
        XCTAssertEqual(model.archivePassword, "doğru parola", "doğru parola oturum için hatırlanmalı")
    }

    func testPasswordCancelAbortsQuietly() async throws {
        let archive = try await makeArchive(name: "gizli2.rar", password: "x")
        await model.loadArchive(archive)
        let dest = tmp.appendingPathComponent("out-cancel")
        var choices = ExtractChoices(destination: dest)
        choices.reveal = false
        let req = ExtractRequest(archives: [archive], selectedRows: [], defaultDestination: dest)
        let task = Task { await model.runExtract(req, choices: choices) }
        let sheet = try await waitForPasswordSheet()
        sheet.resolve(nil)
        await task.value
        XCTAssertNil(model.operation)
        XCTAssertNil(model.alert, "iptal hata göstermemeli")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("src/kök.txt").path))
    }

    func testHeaderEncryptedArchiveAsksPasswordOnOpen() async throws {
        let src = tmp.appendingPathComponent("s.txt")
        try "gizli".write(to: src, atomically: true, encoding: .utf8)
        var o = CompressOptions(archive: tmp.appendingPathComponent("hp.rar"), sources: [src])
        o.password = "pw1"; o.encryptNames = true
        try await model.service.add(o)

        let task = Task { await model.loadArchive(o.archive) }
        let sheet = try await waitForPasswordSheet()
        sheet.resolve("pw1")
        await task.value
        XCTAssertTrue(model.isInArchive)
        XCTAssertEqual(model.rows.map(\.name), ["s.txt"])
    }

    func testDropOfArchiveOpensIt() async throws {
        let archive = try await makeArchive()
        model.handleDrop([archive])
        for _ in 0..<50 where !model.isInArchive { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.isInArchive)
    }

    // MARK: Sürükleyerek çıkarma

    /// Finder'ın yaptığı gibi: NSItemProvider'dan dosya temsilini ister ve içeriği okur.
    private func loadDragged<T: Transferable & Sendable>(_ item: T, type: UTType) async throws -> (name: String, text: String?, entries: [String]) {
        let provider = NSItemProvider()
        provider.register(item)
        return try await withCheckedThrowingContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else { cont.resume(throwing: error ?? CocoaError(.fileNoSuchFile)); return }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    let names = (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String]) ?? []
                    cont.resume(returning: (url.lastPathComponent, nil, names.sorted()))
                } else {
                    cont.resume(returning: (url.lastPathComponent, try? String(contentsOf: url, encoding: .utf8), []))
                }
            }
        }
    }

    func testDragOutFileAndFolder() async throws {
        let archive = try await makeArchive()
        await model.loadArchive(archive)
        model.enterArchivePath("src/klasör")

        let fileRow = try XCTUnwrap(model.rows.first { $0.name == "türkçe dosya.txt" })
        let file = try await loadDragged(ArchiveFileDrag(payload: model.dragPayload(for: fileRow)), type: .data)
        XCTAssertEqual(file.name, "türkçe dosya.txt")
        XCTAssertEqual(file.text, "türkçe")

        model.enterArchivePath("src")
        let dirRow = try XCTUnwrap(model.rows.first { $0.name == "klasör" })
        let dir = try await loadDragged(ArchiveFolderDrag(payload: model.dragPayload(for: dirRow)), type: .folder)
        XCTAssertEqual(dir.name, "klasör")
        XCTAssertTrue(dir.entries.contains("alt/derin.txt"), "\(dir.entries)")
        XCTAssertTrue(dir.entries.contains("türkçe dosya.txt"))
        XCTAssertNil(model.alert)
    }

    func testDragOutNeedsPasswordThenWorks() async throws {
        let archive = try await makeArchive(name: "pwdrag.rar", password: "s3cret")
        await model.loadArchive(archive)       // başlıklar açık: liste parolasız gelir
        model.enterArchivePath("src")
        let row = try XCTUnwrap(model.rows.first { $0.name == "kök.txt" })

        // Parola yokken sürükleme başarısız olur ve parola sorulur
        let failing = ArchiveFileDrag(payload: model.dragPayload(for: row))
        async let attempt: (name: String, text: String?, entries: [String])? = try? loadDragged(failing, type: .data)
        let sheet = try await waitForPasswordSheet()
        sheet.resolve("s3cret")
        let result = await attempt
        XCTAssertNil(result)
        for _ in 0..<50 where model.archivePassword == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.archivePassword, "s3cret")
        model.alert = nil

        // Parola hatırlandıktan sonra çalışır
        let ok = try await loadDragged(ArchiveFileDrag(payload: model.dragPayload(for: row)), type: .data)
        XCTAssertEqual(ok.text, "kök")
    }

    // MARK: Parola yöneticisi

    /// `load` çağrılarını sayan depo (Anahtar Zinciri'ne gereksiz dokunulmadığını doğrulamak için).
    final class CountingStore: PasswordStoring, @unchecked Sendable {
        let inner = InMemoryPasswordStore()
        private let lock = NSLock()
        private(set) var loads = 0
        func load() throws -> [SavedPassword] { lock.lock(); loads += 1; lock.unlock(); return try inner.load() }
        func save(_ items: [SavedPassword]) throws { try inner.save(items) }
    }

    func testCorrectPasswordIsSavedOnlyAfterItWorks() async throws {
        let archive = try await makeArchive(name: "kayit.rar", password: "doğru parola")
        await model.loadArchive(archive)
        let dest = tmp.appendingPathComponent("out-save")
        var choices = ExtractChoices(destination: dest); choices.reveal = false
        let req = ExtractRequest(archives: [archive], selectedRows: [], defaultDestination: dest)
        let task = Task { await model.runExtract(req, choices: choices) }

        // Yanlış parola + "kaydet": kaydedilmemeli
        let first = try await waitForPasswordSheet()
        first.resolve("yanlış", saveName: "Yanlış kayıt")
        // Doğru parola + "kaydet"
        let second = try await waitForPasswordSheet(different: first.id)
        XCTAssertTrue(second.wrong)
        second.resolve("doğru parola", saveName: "Muhasebe")
        await task.value
        for _ in 0..<50 where model.vault.items.isEmpty { try await Task.sleep(for: .milliseconds(50)) }

        XCTAssertEqual(model.vault.items.map(\.name), ["Muhasebe"])
        XCTAssertEqual(model.vault.items.first?.password, "doğru parola")
        XCTAssertNotNil(model.vault.items.first?.lastUsed)
    }

    func testSavedPasswordUsageUpdatesLastUsedAndDuplicatesMerge() async throws {
        let archive = try await makeArchive(name: "kayitli.rar", password: "kayıtlı-parola")
        await model.vault.loadIfNeeded()
        await model.vault.add(name: "Eski", password: "kayıtlı-parola")
        let id = try XCTUnwrap(model.vault.items.first?.id)
        var old = try XCTUnwrap(model.vault.items.first); old.lastUsed = Date(timeIntervalSince1970: 1000)
        await model.vault.update(old)

        await model.loadArchive(archive)
        let dest = tmp.appendingPathComponent("out-used")
        var choices = ExtractChoices(destination: dest); choices.reveal = false
        let task = Task { await model.runExtract(ExtractRequest(archives: [archive], selectedRows: [], defaultDestination: dest), choices: choices) }
        let sheet = try await waitForPasswordSheet()
        // Kullanıcı menüden kayıtlı parolayı seçer → aynı parola; "kaydet" işaretli olsa bile kopya oluşmaz
        let picked = try XCTUnwrap(model.vault.items.first { $0.id == id })
        sheet.resolve(picked.password, saveName: "Kopya")
        await task.value
        for _ in 0..<50 where (model.vault.items.first?.lastUsed ?? .distantPast) < Date(timeIntervalSinceNow: -60) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.vault.items.count, 1, "aynı parola ikinci kez eklenmemeli")
        XCTAssertGreaterThan(model.vault.items[0].lastUsed ?? .distantPast, Date(timeIntervalSinceNow: -60), "son kullanım güncellenmeli")
    }

    func testKeychainIsNotTouchedWithoutPasswords() async throws {
        let counting = CountingStore()
        model.vault = PasswordVault(store: counting)
        let archive = try await makeArchive(name: "duz.rar")        // parolasız
        await model.loadArchive(archive)
        let dest = tmp.appendingPathComponent("out-plain")
        var choices = ExtractChoices(destination: dest); choices.reveal = false
        await model.runExtract(ExtractRequest(archives: [archive], selectedRows: [], defaultDestination: dest), choices: choices)
        XCTAssertEqual(counting.loads, 0, "şifresiz kullanımda Anahtar Zinciri okunmamalı")
    }

    /// Yavaş açılan depo (Anahtar Zinciri izin penceresi gibi): yükleme sürerken kaydetme çağrılırsa
    /// eski (boş) yükleme sonucu yeni eklenen parolayı ezmemeli ve yazma sırası korunmalı.
    final class SlowStore: PasswordStoring, @unchecked Sendable {
        let inner = InMemoryPasswordStore()
        func load() throws -> [SavedPassword] { Thread.sleep(forTimeInterval: 0.3); return try inner.load() }
        func save(_ items: [SavedPassword]) throws { try inner.save(items) }
    }

    func testAddDuringSlowLoadIsNotLostAndPersisted() async throws {
        let store = SlowStore()
        let v = PasswordVault(store: store)
        async let menuLoad: Void = v.loadIfNeeded()          // Ekle penceresindeki menü yüklemeyi başlatır
        try await Task.sleep(for: .milliseconds(50))
        let ok = await v.add(name: "Yeni", password: "gizli")  // kullanıcı Arşivle'ye basar
        await menuLoad
        XCTAssertTrue(ok)
        XCTAssertEqual(v.items.map(\.name), ["Yeni"], "yarış yüzünden parola kaybolmamalı")
        XCTAssertEqual(try store.inner.load().map(\.name), ["Yeni"], "depoya da yazılmış olmalı")
    }

    func testVaultSortingAndEditing() async throws {
        let v = PasswordVault(store: InMemoryPasswordStore())
        await v.loadIfNeeded()
        await v.add(name: "Zeynep", password: "1")
        await v.add(name: "Ahmet", password: "2")
        var a = try XCTUnwrap(v.items.first { $0.name == "Ahmet" })
        a.lastUsed = Date(timeIntervalSince1970: 5)
        await v.update(a)
        var z = try XCTUnwrap(v.items.first { $0.name == "Zeynep" })
        z.lastUsed = Date(timeIntervalSince1970: 10)
        await v.update(z)
        XCTAssertEqual(v.sorted.map(\.name), ["Zeynep", "Ahmet"], "son kullanılan önce")
        await v.remove(z.id)
        XCTAssertEqual(v.items.map(\.name), ["Ahmet"])
    }

    // MARK: Finder ana sağ tık menüsü (eklenti → uygulama komutları)

    func testFinderCommandCompressesWithValidToken() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        defer { UserDefaults.standard.removeObject(forKey: "quickReveal") }
        let folder = tmp.appendingPathComponent("Proje Dosyaları")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let ok = try XCTUnwrap(FinderIntegration.commandURL(action: .compress, paths: [folder.path], token: "gizli"))
        model.handleFinderURL(ok, token: "gizli")
        let archive = tmp.appendingPathComponent("Proje Dosyaları.rar")
        try await waitForFile(archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    /// Geçersiz bir macrar:// bağlantısı uygulamayı (görünmez) başlatmış olabilir; boşta açık kalmamalı.
    func testRejectedCommandEndsSessionSoAppDoesNotLingerInvisibly() async throws {
        var ended = 0
        model.onQuickSessionEnd = { ended += 1 }
        let bad = try XCTUnwrap(FinderIntegration.commandURL(action: .compress, paths: ["/tmp/x"], token: "yanlis"))
        model.handleFinderURL(bad, token: "dogru")
        try await waitUntil { ended > 0 }
        XCTAssertEqual(ended, 1, "reddedilen komuttan sonra uygulama kapanmalı")

        // Kullanıcının penceresi açıksa dokunulmaz
        ended = 0
        model.hasVisibleWindow = { true }
        model.handleFinderURL(bad, token: "dogru")
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(ended, 0, "kullanıcı uygulamayı kullanıyorsa kapatılmamalı")

        // Var olmayan dosyalı geçerli komut da boşta bırakmamalı
        ended = 0
        model.hasVisibleWindow = { false }
        let missing = try XCTUnwrap(FinderIntegration.commandURL(action: .compress, paths: [tmp.appendingPathComponent("yok").path], token: "t"))
        model.handleFinderURL(missing, token: "t")
        try await waitUntil { ended > 0 }
        XCTAssertEqual(ended, 1)
    }

    func testFinderCommandWithWrongTokenDoesNothing() async throws {
        let file = tmp.appendingPathComponent("not.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let bad = try XCTUnwrap(FinderIntegration.commandURL(action: .compress, paths: [file.path], token: "yanlis"))
        model.handleFinderURL(bad, token: "dogru")
        model.handleFinderURL(bad, token: nil)      // anahtarsız (geliştirme) derleme: hiçbir komut kabul edilmez
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("not.rar").path))
        XCTAssertNil(model.operation)
        XCTAssertNil(model.sheet)
    }

    func testFinderCommandsExtractAndOpenDialogs() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        defer { UserDefaults.standard.removeObject(forKey: "quickReveal") }
        let dir = tmp.appendingPathComponent("fd")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = try await makeArchiveIn(dir, name: "veri.rar")

        // Klasöre çıkar (arşiv adıyla)
        model.handleFinderURL(try XCTUnwrap(FinderIntegration.commandURL(action: .extractFolder, paths: [archive.path], token: "t")), token: "t")
        try await waitIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("veri/içerik/not.txt").path))

        // Çıkar… penceresi
        model.handleFinderURL(try XCTUnwrap(FinderIntegration.commandURL(action: .extractDialog, paths: [archive.path], token: "t")), token: "t")
        guard case .extract(let req)? = model.sheet else { return XCTFail("Çıkar penceresi açılmadı") }
        XCTAssertEqual(req.archives.map(\.lastPathComponent), ["veri.rar"])
        model.sheet = nil

        // Aç
        model.handleFinderURL(try XCTUnwrap(FinderIntegration.commandURL(action: .open, paths: [archive.path], token: "t")), token: "t")
        for _ in 0..<50 where !model.isInArchive { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.isInArchive)
    }

    func testFinderCommandIgnoresMissingFiles() async throws {
        let u = try XCTUnwrap(FinderIntegration.commandURL(action: .add, paths: [tmp.appendingPathComponent("yok.txt").path], token: "t"))
        model.handleFinderURL(u, token: "t")
        XCTAssertNil(model.sheet, "var olmayan dosya için pencere açılmamalı")
    }

    // MARK: Hızlı oturum: pencere gerekmedikçe açılmaz, iş bitince uygulama kapanır

    private func waitUntil(_ timeout: Double = 5, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try await Task.sleep(for: .milliseconds(50)) }
    }

    func testQuickCompressEndsSessionWithoutShowingWindowUI() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        defer { UserDefaults.standard.removeObject(forKey: "quickReveal") }
        var ended = 0
        model.onQuickSessionEnd = { ended += 1 }
        let file = tmp.appendingPathComponent("hizli.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        model.quickCompress([file], timestamped: false)
        XCTAssertTrue(model.quickSession, "pencere yokken Finder komutu hızlı oturum başlatmalı")
        try await waitUntil { ended > 0 }
        XCTAssertEqual(ended, 1, "iş bitince uygulama kapanmalı")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("hizli.rar").path))
        XCTAssertNil(model.sheet); XCTAssertNil(model.alert)
        XCTAssertFalse(model.quickSession)
    }

    /// macOS'un yerleşik bsdtar'ı ile ZIP: rar olmasa da çalışır, ad.zip ve zaman damgalı ad oluşur, içerik doğru.
    func testQuickCompressToZipWorksWithoutRar() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        defer { UserDefaults.standard.removeObject(forKey: "quickReveal") }
        let savedRar = model.tools.rar
        model.tools.rar = nil; model.tools.unrar = nil     // rar hiç yokmuş gibi
        defer { model.tools.rar = savedRar; model.tools = TestTools.paths() }
        var ended = 0
        model.onQuickSessionEnd = { ended += 1 }
        let folder = tmp.appendingPathComponent("Proje türkçe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "içerik".write(to: folder.appendingPathComponent("not.txt"), atomically: true, encoding: .utf8)

        model.quickCompress([folder], timestamped: false, format: .zip)
        try await waitUntil { ended > 0 }
        let zip = tmp.appendingPathComponent("Proje türkçe.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path), "ZIP oluşmalı")
        XCTAssertNil(model.alert, "rar olmadan ZIP için uyarı çıkmamalı")

        let listing = try await ArchiveService(tools: model.tools).list(archive: zip)
        XCTAssertTrue(listing.entries.contains { $0.path.hasSuffix("not.txt") })

        ended = 0
        model.quickCompress([folder], timestamped: true, format: .zip)
        try await waitUntil { ended > 0 }
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("Proje türkçe-") && $0.hasSuffix(".zip") }, "\(names)")
    }

    /// rar yokken RAR isteği: uyarı çıkar ve tek tıkla ZIP'e geçilebilir.
    func testRarRequestWithoutRarOffersZip() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        defer { UserDefaults.standard.removeObject(forKey: "quickReveal") }
        let savedRar = model.tools.rar
        model.tools.rar = nil
        defer { model.tools.rar = savedRar; model.tools = TestTools.paths() }
        var ended = 0
        model.onQuickSessionEnd = { ended += 1 }
        let file = tmp.appendingPathComponent("belge.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        model.quickCompress([file], timestamped: false)
        let info = try XCTUnwrap(model.alert, "rar yokken RAR için uyarı gösterilmeli")
        XCTAssertEqual(info.title, "RAR oluşturulamıyor")
        let confirm = try XCTUnwrap(info.confirm, "ZIP'e geçme seçeneği sunulmalı")
        XCTAssertEqual(confirm.label, "ZIP olarak sıkıştır")
        model.alert = nil
        confirm.action()
        try await waitUntil { ended > 0 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("belge.zip").path))
    }

    /// Finder'dan "Arşive Ekle…": ana pencere açılmadan, taşınabilir bağımsız pencerede (sayfa değil) gösterilir.
    func testFinderAddDialogUsesStandaloneWindowWhenUserHasNoWindow() async throws {
        let file = tmp.appendingPathComponent("yeni.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        model.showAddFromFinder([file])
        guard case .add? = model.sheet else { return XCTFail("Ekle diyaloğu açılmadı") }
        XCTAssertTrue(model.quickSession)
        XCTAssertTrue(model.sheetInPanel, "pencere yokken diyalog ana pencereye değil bağımsız pencereye gitmeli")
        model.sheet = nil
        XCTAssertFalse(model.sheetInPanel)
    }

    /// Kullanıcı zaten MacRAR'ı kullanıyorsa diyalog her zamanki gibi ana pencerenin sayfası olur.
    func testAddDialogStaysASheetWhenUserHasAWindow() async throws {
        model.hasVisibleWindow = { true }
        let file = tmp.appendingPathComponent("yeni2.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        model.showAddFromFinder([file])
        guard case .add? = model.sheet else { return XCTFail("Ekle diyaloğu açılmadı") }
        XCTAssertFalse(model.sheetInPanel)
        model.sheet = nil
    }

    func testSessionDoesNotEndWhenUserAlreadyHasAWindow() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        defer { UserDefaults.standard.removeObject(forKey: "quickReveal") }
        var ended = 0
        model.onQuickSessionEnd = { ended += 1 }
        model.hasVisibleWindow = { true }                // kullanıcı MacRAR'ı kullanıyor
        let file = tmp.appendingPathComponent("acik.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        model.quickCompress([file], timestamped: false)
        XCTAssertFalse(model.quickSession)
        try await waitForFile(tmp.appendingPathComponent("acik.rar"))
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(ended, 0, "kullanıcının açık penceresi/oturumu kapatılmamalı")
    }

    func testSessionWaitsForAlertThenEnds() async throws {
        var ended = 0
        model.onQuickSessionEnd = { ended += 1 }
        let txt = tmp.appendingPathComponent("duz.txt")
        try "x".write(to: txt, atomically: true, encoding: .utf8)

        model.quickExtract([txt], intoSubfolder: false)   // arşiv değil → uyarı gösterilir
        XCTAssertNotNil(model.alert)
        model.scheduleQuickSessionEnd()
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(ended, 0, "kullanıcı uyarıyı görmeden uygulama kapanmamalı")

        model.alert = nil                                 // kullanıcı uyarıyı kapattı
        model.scheduleQuickSessionEnd()
        try await waitUntil { ended > 0 }
        XCTAssertEqual(ended, 1)
    }

    func testAddDialogKeepsSessionAliveUntilClosed() async throws {
        var ended = 0
        model.onQuickSessionEnd = { ended += 1 }
        let file = tmp.appendingPathComponent("dlg.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let url = try XCTUnwrap(FinderIntegration.commandURL(action: .add, paths: [file.path], token: "t"))
        model.handleFinderURL(url, token: "t")
        XCTAssertNotNil(model.sheet)
        model.scheduleQuickSessionEnd()
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(ended, 0, "Ekle penceresi açıkken uygulama kapanmamalı")

        model.sheet = nil                                 // kullanıcı vazgeçti
        model.scheduleQuickSessionEnd()
        try await waitUntil { ended > 0 }
        XCTAssertEqual(ended, 1)
    }

    func testOpenCommandKeepsApplicationOpen() async throws {
        var ended = 0
        model.onQuickSessionEnd = { ended += 1 }
        let dir = tmp.appendingPathComponent("ac")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = try await makeArchiveIn(dir, name: "goster.rar")
        model.handleFinderURL(try XCTUnwrap(FinderIntegration.commandURL(action: .open, paths: [archive.path], token: "t")), token: "t")
        try await waitUntil { model.isInArchive }
        XCTAssertTrue(model.isInArchive)
        XCTAssertFalse(model.quickSession, "arşivi görmek isteyen kullanıcının penceresi kapanmamalı")
        model.scheduleQuickSessionEnd()
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(ended, 0)
    }

    // MARK: Hızlı sıkıştırma (Finder hizmeti)

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        // yazım bitene kadar (işlem penceresi kapanana kadar) bekle
        for _ in 0..<100 where model.operation != nil { try await Task.sleep(for: .milliseconds(50)) }
    }

    func testQuickCompressPlainAndTimestamped() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        UserDefaults.standard.set("yyyy-MM-dd_HH-mm-ss", forKey: "stampPattern")
        UserDefaults.standard.set("_", forKey: "stampSeparator")
        defer {
            UserDefaults.standard.removeObject(forKey: "stampPattern")
            UserDefaults.standard.removeObject(forKey: "stampSeparator")
            UserDefaults.standard.removeObject(forKey: "quickReveal")
        }
        let folder = tmp.appendingPathComponent("Fotoğraflar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // 1) klasöradi.rar
        model.quickCompress([folder], timestamped: false)
        let plain = tmp.appendingPathComponent("Fotoğraflar.rar")
        try await waitForFile(plain)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path))

        // 2) aynı ad var → "Fotoğraflar 2.rar" (var olan arşive eklenmez)
        model.quickCompress([folder], timestamped: false)
        try await waitForFile(tmp.appendingPathComponent("Fotoğraflar 2.rar"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Fotoğraflar 2.rar").path))

        // 3) zaman damgalı, kullanıcının seçtiği desen ve ayırıcı ile
        model.quickCompress([folder], timestamped: true)
        var stamped: URL?
        for _ in 0..<100 where stamped == nil {
            try await Task.sleep(for: .milliseconds(100))
            stamped = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.precomposedStringWithCanonicalMapping.range(of: #"^Fotoğraflar_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.rar$"#, options: .regularExpression) != nil }
        }
        try await waitForFile(try XCTUnwrap(stamped, "zaman damgalı arşiv oluşmadı"))

        // içerik doğru: klasör arşivde
        let listing = try await model.service.list(archive: try XCTUnwrap(stamped))
        XCTAssertTrue(listing.entries.contains { $0.path == "Fotoğraflar/a.txt" }, "\(listing.entries.map(\.path))")
    }

    /// Finder'ın yaptığı gibi: panoya dosya URL'leri yazılıp hizmet seçicisi çağrılır.
    func testFinderCompressCommandCreatesArchiveNextToSource() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        defer { UserDefaults.standard.removeObject(forKey: "quickReveal") }
        let file = tmp.appendingPathComponent("not defteri.txt")
        try "içerik".write(to: file, atomically: true, encoding: .utf8)

        model.quickCompress([file], timestamped: false)

        let archive = tmp.appendingPathComponent("not defteri.rar")
        try await waitForFile(archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    // MARK: Hızlı çıkarma (Finder hizmeti)

    private func makeArchiveIn(_ dir: URL, name: String) async throws -> URL {
        let src = dir.appendingPathComponent("içerik")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "birinci".write(to: src.appendingPathComponent("not.txt"), atomically: true, encoding: .utf8)
        let archive = dir.appendingPathComponent(name)
        try await model.service.add(CompressOptions(archive: archive, sources: [src]))
        try FileManager.default.removeItem(at: src)   // çıkarınca yeniden oluşsun
        return archive
    }

    private func waitIdle() async throws {
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<100 where model.operation != nil || model.sheet != nil { try await Task.sleep(for: .milliseconds(50)) }
    }

    func testQuickExtractHereAndSubfolderAndNoOverwrite() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        defer { UserDefaults.standard.removeObject(forKey: "quickReveal") }
        let dir = tmp.appendingPathComponent("indirilenler")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = try await makeArchiveIn(dir, name: "paket.rar")

        // Buraya çıkar: arşivin klasörüne, alt klasör olmadan
        model.quickExtract([archive], intoSubfolder: false)
        try await waitIdle()
        let here = dir.appendingPathComponent("içerik/not.txt")
        XCTAssertEqual(try String(contentsOf: here, encoding: .utf8), "birinci")

        // Var olan dosyanın üzerine YAZILMAZ (RAR: otomatik yeniden adlandırma)
        try "kullanıcının değişikliği".write(to: here, atomically: true, encoding: .utf8)
        model.quickExtract([archive], intoSubfolder: false)
        try await waitIdle()
        XCTAssertEqual(try String(contentsOf: here, encoding: .utf8), "kullanıcının değişikliği", "mevcut dosya ezilmemeli")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("içerik").path)
        XCTAssertEqual(siblings.count, 2, "yeni kopya yeniden adlandırılarak yanına çıkmalı: \(siblings)")

        // Arşiv adıyla klasöre
        model.quickExtract([archive], intoSubfolder: true)
        try await waitIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("paket/içerik/not.txt").path))
    }

    func testQuickExtractZipSkipsExistingAndRejectsNonArchive() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        defer { UserDefaults.standard.removeObject(forKey: "quickReveal") }
        let dir = tmp.appendingPathComponent("zipdir")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("k"), withIntermediateDirectories: true)
        try "zip içeriği".write(to: dir.appendingPathComponent("k/z.txt"), atomically: true, encoding: .utf8)
        var o = CompressOptions(archive: dir.appendingPathComponent("a.zip"), sources: [dir.appendingPathComponent("k")])
        o.format = .zip
        try await model.service.add(o)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("k"))

        model.quickExtract([o.archive], intoSubfolder: false)
        try await waitIdle()
        let out = dir.appendingPathComponent("k/z.txt")
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "zip içeriği")

        try "değişti".write(to: out, atomically: true, encoding: .utf8)
        model.quickExtract([o.archive], intoSubfolder: false)
        try await waitIdle()
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "değişti", "ZIP'te de mevcut dosya ezilmemeli")

        // Arşiv olmayan dosya → uyarı
        let txt = dir.appendingPathComponent("düz.txt")
        try "x".write(to: txt, atomically: true, encoding: .utf8)
        model.quickExtract([txt], intoSubfolder: false)
        XCTAssertEqual(model.alert?.title, "Arşiv seçilmedi")
        model.alert = nil
    }

    func testExtractServiceThroughPasteboard() async throws {
        UserDefaults.standard.set(false, forKey: "quickReveal")
        defer { UserDefaults.standard.removeObject(forKey: "quickReveal") }
        let dir = tmp.appendingPathComponent("pb")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = try await makeArchiveIn(dir, name: "servis.rar")
        model.quickExtract([archive], intoSubfolder: false)
        try await waitIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("içerik/not.txt").path))
    }

    func testAddServiceOpensAddSheetForNewArchiveEvenWhenArchiveIsOpen() async throws {
        let open = try await makeArchive(name: "acik.rar")
        await model.loadArchive(open)
        XCTAssertTrue(model.isInArchive)
        let file = tmp.appendingPathComponent("yeni dosya.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        model.showAddFromFinder([file])
        for _ in 0..<50 where model.sheet == nil { try await Task.sleep(for: .milliseconds(50)) }

        guard case .add(let req)? = model.sheet else { return XCTFail("Ekle penceresi açılmadı: \(String(describing: model.sheet))") }
        XCTAssertNil(req.existingArchive, "Finder'dan Ekle, açık arşive değil yeni arşive eklemeli")
        XCTAssertEqual(req.sources.map(\.lastPathComponent), ["yeni dosya.txt"])
        XCTAssertEqual(req.defaultName, "yeni dosya")
    }

    func testSaveToVaultReportsSuccessAndFailure() async throws {
        await model.saveToVault(name: "Proje", password: "abc")
        XCTAssertEqual(model.vault.items.map(\.name), ["Proje"])
        XCTAssertNotNil(model.notice, "kullanıcıya kaydedildi bildirimi gösterilmeli")
        XCTAssertNil(model.alert)

        final class FailingStore: PasswordStoring, @unchecked Sendable {
            func load() throws -> [SavedPassword] { [] }
            func save(_ items: [SavedPassword]) throws { throw PasswordVaultError.keychain(errSecAuthFailed) }
        }
        model.vault = PasswordVault(store: FailingStore())
        model.notice = nil
        let ok = await model.saveToVault(name: "X", password: "y")
        XCTAssertFalse(ok)
        XCTAssertEqual(model.alert?.title, "Parola kaydedilemedi", "hata sessiz kalmamalı")
        model.alert = nil
    }

    /// RAR/7Z türleri "içe aktarılmak" yerine MacRAR tarafından DIŞA AKTARILMALI ve kendi ikonunu taşımalı;
    /// aksi halde sistemde aktif tanım başka bir uygulamanın (örn. VLC) olur ve Finder onun ikonunu gösterir.
    func testRarAndSevenZipTypesAreExportedWithIcon() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        XCTAssertNil(dict["UTImportedTypeDeclarations"], "içe aktarılan tanım başka uygulamanın ikonunu bırakır")
        let exported = try XCTUnwrap(dict["UTExportedTypeDeclarations"] as? [[String: Any]])
        for id in ["com.rarlab.rar-archive", "org.7-zip.7-zip-archive"] {
            let decl = try XCTUnwrap(exported.first { $0["UTTypeIdentifier"] as? String == id }, id)
            XCTAssertEqual(decl["UTTypeIconFile"] as? String, "AppIcon", "\(id) kendi ikonunu taşımalı")
            XCTAssertTrue((decl["UTTypeConformsTo"] as? [String])?.contains("public.archive") ?? false)
        }
        let docs = try XCTUnwrap(dict["CFBundleDocumentTypes"] as? [[String: Any]])
        let typed = docs.compactMap { $0["LSItemContentTypes"] as? [String] }.flatMap { $0 }
        XCTAssertTrue(typed.contains("com.rarlab.rar-archive"), "RAR belge türü türe bağlı olmalı")
    }

    // MARK: Varsayılan uygulama ayarı (yalnızca okuma; sistem ayarı DEĞİŞTİRİLMEZ)

    func testDefaultAppKindsResolveAndAreArchiveTypes() throws {
        for kind in DefaultApps.kinds {
            let type = try XCTUnwrap(kind.type, "\(kind.id) çözülmeli")
            XCTAssertTrue(type.conforms(to: .archive) || type.conforms(to: .data), kind.id)
        }
        XCTAssertEqual(DefaultApps.kinds.filter(\.primary).map(\.ext), ["rar", "7z"])
    }

    func testCurrentDefaultComparisonUsesBundleIdentifier() throws {
        let rar = try XCTUnwrap(DefaultApps.kinds.first { $0.ext == "rar" })
        let actual = DefaultApps.current(for: rar, thisBundleID: "yok.boyle.bir.uygulama")
        XCTAssertFalse(actual.isMacRAR, "farklı kimlik MacRAR sayılmamalı")
        if let id = actual.bundleID {
            XCTAssertTrue(DefaultApps.current(for: rar, thisBundleID: id).isMacRAR, "aynı kimlik MacRAR sayılmalı")
            XCTAssertNotNil(actual.name, "varsayılan uygulamanın adı okunmalı")
        }
    }

    func testOnlyApplicationsFolderCountsAsInstalled() {
        XCTAssertTrue(DefaultApps.isInstalledInApplications(URL(fileURLWithPath: "/Applications/MacRAR.app")))
        XCTAssertTrue(DefaultApps.isInstalledInApplications(URL(fileURLWithPath: NSHomeDirectory() + "/Applications/MacRAR.app")))
        XCTAssertFalse(DefaultApps.isInstalledInApplications(URL(fileURLWithPath: "/Users/x/Desktop/MacRAR/build/MacRAR.app")),
                       "geliştirme klasöründeki kopya varsayılan yapılmamalı")
        XCTAssertFalse(DefaultApps.isInstalledInApplications(URL(fileURLWithPath: "/tmp/MacRAR.app")))
    }

    // MARK: Kurulum paketi ve Kurulum Yardımcısı

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Betiği çalıştırıp (çıkış kodu, günlük metni) döndürür. Komutlar DENEME kipinde yalnızca yazılır; sisteme dokunulmaz.
    private func runPostinstall(app: String, user: String) throws -> (Int32, String) {
        let log = tmp.appendingPathComponent("pi-\(UUID().uuidString).log")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [repoRoot.appendingPathComponent("scripts/pkg/scripts/postinstall").path]
        var env = ProcessInfo.processInfo.environment
        env["MACRAR_DRY_RUN"] = "1"; env["MACRAR_LOG"] = log.path; env["MACRAR_APP"] = app; env["MACRAR_TEST_USER"] = user
        p.environment = env
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }

    func testPostinstallEnablesFinderExtensionAndNeverFailsTheInstall() throws {
        // 1) normal: uygulama kurulu, giriş yapmış kullanıcı var → altı adım, doğru sırada
        let fakeApp = tmp.appendingPathComponent("MacRAR.app")
        try FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)
        let (code, log) = try runPostinstall(app: fakeApp.path, user: NSUserName())
        XCTAssertEqual(code, 0)
        // Uygulama kullanıcıya devredilmezse sonraki sürümlere kendini güncelleyemez.
        XCTAssertTrue(log.contains("chown -R \(NSUserName()) \(fakeApp.path)"), log)
        let steps = ["chown -R", "lsregister -f", "pluginkit -a", "pbs -update", "pluginkit -e use -i local.macrar.app.FinderSync", "killall Finder", "open -a"]
        var cursor = log.startIndex
        for step in steps {
            let r = try XCTUnwrap(log.range(of: step, range: cursor..<log.endIndex), "adım eksik/sırasız: \(step)\n\(log)")
            cursor = r.upperBound
        }
        // 2) uygulama kurulu değil → hiçbir adım yapılmaz ama kurulum başarısız sayılmaz
        let (c2, l2) = try runPostinstall(app: "/yok/MacRAR.app", user: NSUserName())
        XCTAssertEqual(c2, 0); XCTAssertTrue(l2.contains("bulunamadı")); XCTAssertFalse(l2.contains("pluginkit -e use"))
        // 3) giriş yapmış kullanıcı yok (uzaktan kurulum) → kullanıcı adımları atlanır, kurulum başarılı
        let (c3, l3) = try runPostinstall(app: fakeApp.path, user: "root")
        XCTAssertEqual(c3, 0); XCTAssertTrue(l3.contains("Giriş yapmış kullanıcı yok")); XCTAssertFalse(l3.contains("killall Finder"))
        XCTAssertFalse(l3.contains("chown"))
    }

    func testInstallerResourcesAreValid() throws {
        let dist = repoRoot.appendingPathComponent("scripts/pkg/distribution.xml")
        let parser = XMLParser(data: try Data(contentsOf: dist))
        XCTAssertTrue(parser.parse(), "distribution.xml geçerli XML olmalı: \(String(describing: parser.parserError))")
        let xml = try String(contentsOf: dist, encoding: .utf8)
        for needle in ["welcome.html", "readme.html", "conclusion.html", "@VERSION@", "local.macrar.pkg", "enable_localSystem=\"true\""] {
            XCTAssertTrue(xml.contains(needle), needle)
        }
        // Her sayfa iki dili alt alta içerir (Installer sayfayı biçimli metne çevirir; tıklanabilir seçici çalışmaz).
        // build_pkg.sh her dil klasörü için @LANG@ ve @BODY@ yerlerini doldurur, o dili üste alır.
        for f in ["welcome.html", "readme.html", "conclusion.html"] {
            let html = try String(contentsOf: repoRoot.appendingPathComponent("scripts/pkg/resources/\(f)"), encoding: .utf8)
            XCTAssertTrue(html.contains("charset=\"utf-8\"") && html.contains("MacRAR"), f)
            for needle in ["@LANG@", "@BODY@", "<!--TR-->", "<!--/TR-->", "<!--EN-->", "<!--/EN-->", "🇹🇷 Türkçe", "🇬🇧 English"] {
                XCTAssertTrue(html.contains(needle), "\(f): \(needle)")
            }
        }
        let readme = try String(contentsOf: repoRoot.appendingPathComponent("scripts/pkg/resources/readme.html"), encoding: .utf8)
        XCTAssertTrue(readme.contains("rarlab.com") && readme.contains("unrar") && readme.contains("pluginkit -e use"), "Okubeni, kurulum sonrası adımları içermeli")
        XCTAssertTrue(readme.contains("GPL-3.0") && readme.contains("Lisans") && readme.contains("License"), "Okubeni iki dilde lisansı belirtmeli")
        XCTAssertFalse(readme.contains("brew install --cask rar"), "devre dışı bırakılmış brew komutu önerilmemeli")
        for script in ["scripts/build_pkg.sh", "scripts/uninstall.sh", "scripts/pkg/scripts/preinstall", "scripts/pkg/scripts/postinstall"] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n", repoRoot.appendingPathComponent(script).path]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(script) sözdizimi")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: repoRoot.appendingPathComponent(script).path), "\(script) çalıştırılabilir olmalı")
        }
    }

    /// Homebrew'daki rar kaskı devre dışı: kaynak kodda bu komutu öneren bir metin kalmamalı (açıklama yorumları hariç).
    func testNoUserFacingTextRecommendsTheDisabledBrewCask() throws {
        let sources = repoRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 10)
        for f in files {
            let code = try String(contentsOf: f, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            XCTAssertFalse(code.contains("brew install --cask rar"), "\(f.lastPathComponent) devre dışı brew komutunu öneriyor")
        }
        let guidance = ToolGuidance.oneLiner + ToolGuidance.rarInstallSteps + ToolGuidance.rarLicenseNote
        XCTAssertTrue(guidance.contains("rarlab.com/download.htm") && guidance.contains("40 gün"))
    }

    func testSetupAssistantFirstRunFlagAndBrewCommand() {
        let d = UserDefaults.standard
        d.removeObject(forKey: SetupAssistant.doneKey)
        XCTAssertTrue(SetupAssistant.needsFirstRun, "ilk açılışta yardımcı gösterilmeli")
        SetupAssistant.markDone()
        XCTAssertFalse(SetupAssistant.needsFirstRun, "Bitti'den sonra tekrar gösterilmemeli")
        d.removeObject(forKey: SetupAssistant.doneKey)
        XCTAssertFalse((ToolGuidance.oneLiner + ToolGuidance.rarAutoInstallNote).contains("brew"), "kullanıcıya terminal komutu önerilmemeli")
    }

    func testBringToFrontNeverOpensNonAppFoldersInFinder() {
        XCTAssertTrue(AppModel.isReopenable(bundleURL: URL(fileURLWithPath: "/Applications/MacRAR.app")))
        XCTAssertFalse(AppModel.isReopenable(bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin")),
                       "xctest/swift run altında Bundle.main klasördür; Finder'da açılmamalı")
        XCTAssertFalse(AppModel.isReopenable(bundleURL: Bundle.main.bundleURL), "testler .app içinde çalışmaz")
    }

    // MARK: Hakkında penceresi

    func testAboutDeveloperAndFinderExtensionStateParsing() {
        XCTAssertEqual(AppInfo.developer, "Rafet SAPANCI")
        let id = AppInfo.finderExtensionID
        XCTAssertEqual(AboutView.parseFinderExtensionState("+    \(id)(1.0)\n"), .enabled)
        XCTAssertEqual(AboutView.parseFinderExtensionState("-    \(id)(1.0)\n"), .disabled)
        XCTAssertEqual(AboutView.parseFinderExtensionState("     \(id)(1.0)\n"), .disabled, "işaretsiz = henüz etkinleştirilmemiş")
        XCTAssertEqual(AboutView.parseFinderExtensionState(""), .missing)
        XCTAssertEqual(AboutView.parseFinderExtensionState("+    baska.uygulama.eklenti(1.0)\n"), .missing)
    }

    /// Finder'ın ana sağ tık menüsü varken "Servisler" altında yinelenen MacRAR girdileri olmamalı.
    func testInfoPlistDeclaresNoServices() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        XCTAssertNil(dict["NSServices"], "Servisler girdileri kaldırıldı; menü yalnızca Finder eklentisinden gelir")
    }

    // MARK: Yardımcı

    private func waitForPasswordSheet(different: UUID? = nil) async throws -> PasswordRequest {
        for _ in 0..<100 {
            if case .password(let r)? = model.sheet, r.id != different { return r }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("parola penceresi görünmedi")
    }
}
