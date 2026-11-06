import XCTest
import CryptoKit
@testable import MacRARCore

/// Kendini güncelleme: GitLab yanıtı, sürüm karşılaştırma ve zip denetimi. Ağ ve pencere kullanılmaz; sahte uygulama
/// geçici klasörde ad-hoc imzalanır, `file://` ile "indirilir".
final class UpdateTests: XCTestCase {
    private var tmp: URL!
    private let fm = FileManager.default
    private let bundleID = "local.macrar.test"

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("macrar-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    // MARK: Yanıt

    private func json(tag: String = "v1.2.0", zip: String = "https://gitlab.com/freeware2/macrar/-/releases/v1.2.0/downloads/MacRAR.zip",
                      page: String = "https://gitlab.com/freeware2/macrar/-/releases/v1.2.0") -> Data {
        Data("""
        {"tag_name":"\(tag)","description":"Notlar","_links":{"self":"\(page)"},"assets":{"links":[
          {"name":"MacRAR.zip","url":"https://gitlab.com/api/x","direct_asset_url":"\(zip)"},
          {"name":"MacRAR.zip.sha256","url":"https://gitlab.com/api/y/MacRAR.zip.sha256"}]}}
        """.utf8)
    }

    func testParseReadsTheRelease() throws {
        let r = try UpdateInfo.parse(json())
        XCTAssertEqual(r.version, "1.2.0")
        XCTAssertEqual(r.notes, "Notlar")
        XCTAssertEqual(r.archive?.lastPathComponent, "MacRAR.zip")
        XCTAssertEqual(r.checksum?.lastPathComponent, "MacRAR.zip.sha256")
        XCTAssertEqual(r.page.absoluteString, "https://gitlab.com/freeware2/macrar/-/releases/v1.2.0")
    }

    func testOnlyGitLabAddressesAreAccepted() throws {
        for bad in ["https://evil.example/MacRAR.zip", "http://gitlab.com/MacRAR.zip", "https://gitlab.com.evil.example/MacRAR.zip",
                    "file:///tmp/MacRAR.zip"] {
            XCTAssertNil(try UpdateInfo.parse(json(zip: bad)).archive, bad)
        }
        XCTAssertEqual(try UpdateInfo.parse(json(page: "https://evil.example/")).page, UpdateInfo.releasesPage)
        XCTAssertNotNil(try UpdateInfo.parse(json(zip: "file:///tmp/MacRAR.zip"), allowFileURLs: true).archive)
    }

    func testOlderReleaseWithoutZipHasNoArchive() throws {
        let data = Data(#"{"tag_name":"v1.1.3","assets":{"links":[{"name":"MacRAR-1.1.3.pkg","url":"https://gitlab.com/x"}]}}"#.utf8)
        let r = try UpdateInfo.parse(data)
        XCTAssertNil(r.archive)
        XCTAssertNil(r.checksum)
        XCTAssertEqual(r.page, UpdateInfo.releasesPage)
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateInfo.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(UpdateInfo.isNewer("1.2.1", than: "1.2"))
        XCTAssertTrue(UpdateInfo.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertFalse(UpdateInfo.isNewer("1.2.0", than: "1.2"))
        XCTAssertFalse(UpdateInfo.isNewer("1.1.3", than: "1.2.0"))
    }

    func testChecksumParsing() {
        let hex = String(repeating: "AB", count: 32)
        XCTAssertEqual(UpdateInfo.parseChecksum("\(hex)  MacRAR.zip\n"), hex.lowercased())
        XCTAssertEqual(UpdateInfo.parseChecksum(hex), hex.lowercased())
        XCTAssertNil(UpdateInfo.parseChecksum("abc  MacRAR.zip"))
        XCTAssertNil(UpdateInfo.parseChecksum(""))
    }

    func testWhatsNewPicksTheInterfaceLanguage() {
        let notes = """
        ## What's new in 1.2.0

        - **Updates:** MacRAR updates `itself`.

        ## Install
        Steps

        ---

        ### 1.2.0'daki yenilikler

        - **Güncelleme:** MacRAR kendini günceller.

        ### Kurulum
        """
        XCTAssertEqual(UpdateInfo.whatsNew(in: notes, turkish: false), "- Updates: MacRAR updates itself.")
        XCTAssertEqual(UpdateInfo.whatsNew(in: notes, turkish: true), "- Güncelleme: MacRAR kendini günceller.")
        XCTAssertEqual(UpdateInfo.whatsNew(in: "Başlıksız not", turkish: true), "Başlıksız not")
    }

    func testRelaunchScriptRefreshesExtensionOnlyIfItWasOn() throws {
        let script = UpdateInfo.relaunchScript(processID: 4242)
        var cursor = script.startIndex
        for step in ["kill -0 4242", "lsregister -f \"$0\"", "pluginkit -a \"$0/Contents/PlugIns/MacRARFinder.appex\"", "pbs -update",
                     "if [ \"$1\" = \"1\" ]", "pluginkit -e use -i local.macrar.app.FinderSync", "killall MacRARFinder", "fi", "open \"$0\""] {
            let r = try XCTUnwrap(script.range(of: step, range: cursor..<script.endIndex), step)
            cursor = r.upperBound
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", "-c", script]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    // MARK: Zip denetimi

    private func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(tool) \(args)")
    }

    private func writeBundle(_ root: URL, id: String, version: String, executable: String) throws {
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let tool = contents.appendingPathComponent("MacOS/\(executable)")
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: tool)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": executable]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// Sürüm dizinine `MacRAR.app` üretir, imzalar; `tamper` imzadan sonra pakete dokunur.
    private func makeRelease(version: String = "9.9.9", id: String? = nil, withExtension: Bool = true,
                             tamper: ((URL) throws -> Void)? = nil, checksum: String? = nil) throws -> UpdateRelease {
        let dir = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = dir.appendingPathComponent("MacRAR.app", isDirectory: true)
        try writeBundle(app, id: id ?? bundleID, version: version, executable: "MacRAR")
        let appex = app.appendingPathComponent(UpdateInfo.finderExtensionPath, isDirectory: true)
        if withExtension {
            try writeBundle(appex, id: "\(bundleID).FinderSync", version: version, executable: "MacRARFinder")
            try run("/usr/bin/codesign", "--force", "--sign", "-", appex.path)
        }
        try run("/usr/bin/codesign", "--force", "--sign", "-", app.path)
        try tamper?(app)
        let zip = dir.appendingPathComponent(UpdateInfo.archiveName)
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        let sum = dir.appendingPathComponent(UpdateInfo.checksumName)
        try "\(checksum ?? digest)  MacRAR.zip\n".write(to: sum, atomically: true, encoding: .utf8)
        return UpdateRelease(version: "9.9.9", notes: "", page: UpdateInfo.releasesPage, archive: zip, checksum: sum)
    }

    private func installedApp() throws -> URL {
        let folder = tmp.appendingPathComponent("Applications-\(UUID().uuidString)", isDirectory: true)
        let app = folder.appendingPathComponent("MacRAR.app", isDirectory: true)
        try writeBundle(app, id: bundleID, version: "1.0.0", executable: "MacRAR")
        return app
    }

    private func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")))?["CFBundleShortVersionString"] as? String
    }

    private func assertRefused(_ release: UpdateRelease, _ expected: Updater.Failure,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let current = try installedApp()
        do {
            _ = try await Updater.prepare(release, replacing: current, bundleID: bundleID)
            XCTFail("kabul edildi", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? Updater.Failure, expected, file: file, line: line)
        }
        XCTAssertEqual(version(of: current), "1.0.0", file: file, line: line)
    }

    func testGoodReleaseReplacesTheApp() async throws {
        let current = try installedApp()
        let prepared = try await Updater.prepare(try makeRelease(), replacing: current, bundleID: bundleID)
        XCTAssertEqual(version(of: current), "1.0.0", "denetim sırasında uygulamaya dokunulmaz")
        try Updater.replace(appAt: current, with: prepared)
        prepared.discard()
        XCTAssertEqual(version(of: current), "9.9.9")
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent(UpdateInfo.finderExtensionPath).path))
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", current.path)
    }

    func testWrongChecksumIsRefused() async throws {
        try await assertRefused(try makeRelease(checksum: String(repeating: "0", count: 64)), .checksumMismatch)
    }

    func testUnreadableChecksumIsRefused() async throws {
        try await assertRefused(try makeRelease(checksum: "xyz"), .unreadableChecksum)
    }

    func testOtherBundleIDIsRefused() async throws {
        try await assertRefused(try makeRelease(id: "com.example.other"), .wrongApp)
    }

    func testVersionMismatchWithTagIsRefused() async throws {
        try await assertRefused(try makeRelease(version: "9.9.8"), .wrongApp)
    }

    func testAppWithoutFinderExtensionIsRefused() async throws {
        try await assertRefused(try makeRelease(withExtension: false), .wrongApp)
    }

    func testTamperedAppIsRefused() async throws {
        let release = try makeRelease(tamper: { app in
            try Data("kurcalandı".utf8).write(to: app.appendingPathComponent("Contents/MacOS/MacRAR"))
        })
        try await assertRefused(release, .badSignature)
    }

    func testTamperedExtensionIsRefused() async throws {
        let release = try makeRelease(tamper: { app in
            try Data("kurcalandı".utf8).write(to: app.appendingPathComponent(UpdateInfo.finderExtensionPath).appendingPathComponent("Contents/MacOS/MacRARFinder"))
        })
        try await assertRefused(release, .badSignature)
    }

    func testReleaseWithoutFilesIsRefused() async throws {
        let bare = UpdateRelease(version: "9.9.9", notes: "", page: UpdateInfo.releasesPage, archive: nil, checksum: nil)
        try await assertRefused(bare, .missingFiles)
    }

    func testCanReplaceAppRequiresWritableBundleAndFolder() throws {
        let app = try installedApp()
        XCTAssertTrue(Updater.canReplaceApp(at: app))
        XCTAssertFalse(Updater.canReplaceApp(at: tmp), "uygulama paketi değil")
        let folder = app.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        XCTAssertFalse(Updater.canReplaceApp(at: app))
    }
}
