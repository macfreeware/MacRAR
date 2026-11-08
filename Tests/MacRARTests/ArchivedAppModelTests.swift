import XCTest
import MacRARCore
@testable import MacRAR

/// Arşivdeki uygulama akışı: gerçek zip, geçici "Uygulamalar" klasörü. Pencere açılmaz, Finder'a dokunulmaz.
@MainActor
final class ArchivedAppModelTests: XCTestCase {
    var tmp: URL!
    var apps: URL!
    var revealed: [URL] = []
    var model: AppModel { AppModel.shared }
    let fm = FileManager.default

    override func setUp() async throws {
        var tools = TestTools.paths()
        try XCTSkipUnless(tools.bsdtar != nil, "bsdtar yok")
        tools.rar = nil
        tools.unrar = nil
        model.tools = tools
        tmp = fm.temporaryDirectory.appendingPathComponent("macrar-appflow-\(UUID().uuidString)", isDirectory: true)
        apps = tmp.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        model.closeArchive()
        model.sheet = nil
        model.operation = nil
        model.alert = nil
        model.hasVisibleWindow = { false }
        model.applicationsFolder = apps
        revealed = []
        model.revealInFinder = { [weak self] in self?.revealed += $0 }
        SheetPanel.isEnabled = false
    }

    override func tearDown() async throws {
        model.closeArchive()
        model.alert = nil
        model.applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        model.revealInFinder = { NSWorkspace.shared.activateFileViewerSelecting($0) }
        try? fm.removeItem(at: tmp)
    }

    private func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(tool) \(args)")
    }

    private func makeApp(at url: URL, version: String, id: String = "local.macrar.fake") throws {
        let macos = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("Deneme"))
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version,
                                    "CFBundleExecutable": "Deneme", "CFBundleName": "Deneme Uygulama"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", "--force", "--sign", "-", url.path)
    }

    /// Yanında uygulama olan bir zip oluşturup açar.
    private func openZip(version: String = "2.0", id: String = "local.macrar.fake") async throws -> ArchivedApp {
        let src = tmp.appendingPathComponent("kaynak", isDirectory: true)
        let app = src.appendingPathComponent("Deneme.app", isDirectory: true)
        try makeApp(at: app, version: version, id: id)
        let zip = tmp.appendingPathComponent("Deneme.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        try fm.removeItem(at: src)
        await model.loadArchive(zip)
        XCTAssertEqual(model.archivedApps.count, 1)
        return try XCTUnwrap(model.archivedApps.first)
    }

    private func version(_ app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")))?["CFBundleShortVersionString"] as? String
    }

    func testAppIsRecognizedWithDetailsAndRowOffersChoices() async throws {
        let app = try await openZip()
        for _ in 0..<200 where model.archivedAppDetails[app.path] == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.archivedAppDetails[app.path]?.info.version, "2.0")
        XCTAssertEqual(model.displayName(of: app), "Deneme Uygulama")

        let row = try XCTUnwrap(model.rows.first { $0.name == "Deneme.app" })
        XCTAssertNotNil(model.archivedAppIcon(for: row))
        model.open(row)
        let alert = try XCTUnwrap(model.alert)
        XCTAssertEqual(alert.extras.count, 2)
        XCTAssertTrue(model.archivePath.isEmpty, "çift tıklama klasöre girmez")

        alert.extras[1].action()   // İçeriğe Bak
        XCTAssertEqual(model.archivePath, "Deneme.app")
        model.alert = nil
    }

    func testClosingArchiveClearsApps() async throws {
        _ = try await openZip()
        model.closeArchive()
        XCTAssertTrue(model.archivedApps.isEmpty)
    }

    func testOrdinaryZipHasNoApp() async throws {
        let file = tmp.appendingPathComponent("yazi.txt")
        try Data("x".utf8).write(to: file)
        let zip = tmp.appendingPathComponent("yazi.zip")
        try run("/usr/bin/ditto", "-c", "-k", file.path, zip.path)
        await model.loadArchive(zip)
        XCTAssertTrue(model.archivedApps.isEmpty)
    }

    func testExtractPutsAppNextToArchiveWithoutOverwriting() async throws {
        let app = try await openZip()
        let zip = try XCTUnwrap(model.archiveURL)
        let value = Data("0081;00000000;Test;".utf8)
        Quarantine.apply(value, to: [zip])

        await model.extractArchivedApp(app)
        let first = tmp.appendingPathComponent("Deneme.app")
        XCTAssertEqual(version(first), "2.0")
        XCTAssertEqual(revealed, [first])
        XCTAssertEqual(Quarantine.value(of: first), value, "karantina paketin kendisine de taşınır")
        XCTAssertEqual(Quarantine.value(of: first.appendingPathComponent("Contents/MacOS/Deneme")), value)
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", first.path)

        await model.extractArchivedApp(app)
        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("Deneme 2.app").path))
        XCTAssertEqual(version(first), "2.0")
    }

    func testInstallIntoEmptyFolderReportsSuccess() async throws {
        let app = try await openZip()
        await model.installArchivedApp(app)
        XCTAssertEqual(version(apps.appendingPathComponent("Deneme.app")), "2.0")
        let alert = try XCTUnwrap(model.alert)
        XCTAssertEqual(alert.confirm?.label, String(localized: "Aç"))
        alert.extras[0].action()
        XCTAssertEqual(revealed, [apps.appendingPathComponent("Deneme.app")])
        model.alert = nil
    }

    func testExistingAppIsNotReplacedWithoutConfirmation() async throws {
        try makeApp(at: apps.appendingPathComponent("Deneme.app"), version: "1.0")
        let app = try await openZip()
        await model.installArchivedApp(app)
        XCTAssertEqual(version(apps.appendingPathComponent("Deneme.app")), "1.0", "onay olmadan değişmez")
        let alert = try XCTUnwrap(model.alert)
        XCTAssertTrue(alert.message.contains("1.0"), alert.message)
        XCTAssertTrue(alert.message.contains("2.0"), alert.message)
        XCTAssertFalse(alert.message.contains(String(localized: "Dikkat: Var olan uygulama aynı adda ama farklı bir uygulama.")))
        alert.onCancel?()
        model.alert = nil
    }

    func testDifferentAppWithSameNameWarns() async throws {
        try makeApp(at: apps.appendingPathComponent("Deneme.app"), version: "1.0", id: "com.example.baska")
        let app = try await openZip()
        await model.installArchivedApp(app)
        let alert = try XCTUnwrap(model.alert)
        XCTAssertTrue(alert.message.contains(String(localized: "Dikkat: Var olan uygulama aynı adda ama farklı bir uygulama.")), alert.message)
        alert.onCancel?()
        model.alert = nil
    }

    func testMacRARDoesNotInstallItself() async throws {
        let id = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let app = try await openZip(id: id)
        await model.installArchivedApp(app)
        XCTAssertFalse(fm.fileExists(atPath: apps.appendingPathComponent("Deneme.app").path))
        XCTAssertNil(model.alert?.confirm)
        XCTAssertNotNil(model.alert)
        model.alert = nil
    }
}
