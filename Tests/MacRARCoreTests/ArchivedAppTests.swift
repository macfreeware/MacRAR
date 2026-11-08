import XCTest
@testable import MacRARCore

/// Arşivdeki Mac uygulamalarını tanıma ve yerine koyma. Ağ ve pencere kullanılmaz; her şey geçici klasördedir.
final class ArchivedAppTests: XCTestCase {
    private var tmp: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("macrar-app-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func files(_ paths: String...) -> [ArchiveEntry] {
        paths.map { ArchiveEntry(path: $0, isDirectory: false, size: 1) }
    }

    private func app(_ root: String) -> [String] { ["\(root)/Contents/Info.plist", "\(root)/Contents/MacOS/X"] }

    private func entries(_ groups: [String]...) -> [ArchiveEntry] {
        groups.flatMap { $0 }.map { ArchiveEntry(path: $0, isDirectory: false, size: 1) }
    }

    // MARK: Tanıma

    func testFindsAppAtRoot() {
        XCTAssertEqual(ArchivedApps.find(in: entries(app("MacExplorer.app"))), [ArchivedApp(path: "MacExplorer.app")])
    }

    func testFindsAppInSingleFolderWithLicense() {
        XCTAssertEqual(ArchivedApps.find(in: entries(app("MacZilla/MacZilla.app"), ["MacZilla/LICENSE.txt"])), [ArchivedApp(path: "MacZilla/MacZilla.app")])
    }

    func testIgnoresMetadataRecords() {
        let list = entries(app("__MACOSX/X.app"), ["X.app/Contents/._Info.plist", "X.app/Contents/MacOS/._X"], app("Y.app"))
        XCTAssertEqual(ArchivedApps.find(in: list), [ArchivedApp(path: "Y.app")])
    }

    func testHelperAppsInsideAnAppAreNotCounted() {
        let list = entries(app("Main.app"), app("Main.app/Contents/Library/Helper.app"), app("Main.app/Helper.app"))
        XCTAssertEqual(ArchivedApps.find(in: list), [ArchivedApp(path: "Main.app")])
    }

    func testFolderNamedLikeAnAppIsNotAnApp() {
        XCTAssertEqual(ArchivedApps.find(in: files("Foo.app/readme.txt", "Foo.app/Contents/notes.txt")), [])
        XCTAssertEqual(ArchivedApps.find(in: files("Foo.app/Contents/Info.plist")), [], "çalıştırılabilir dosya yok")
        XCTAssertEqual(ArchivedApps.find(in: files("Foo.app/Contents/MacOS/X")), [], "Info.plist yok")
        XCTAssertEqual(ArchivedApps.find(in: files(".app/Contents/Info.plist", ".app/Contents/MacOS/X")), [])
    }

    func testDeeplyNestedAppIsNotOffered() {
        XCTAssertEqual(ArchivedApps.find(in: entries(app("a/b/C.app"))), [])
    }

    func testSourceArchiveHasNoApp() {
        XCTAssertEqual(ArchivedApps.find(in: files("macexplorer-v1.3.4/Package.swift", "macexplorer-v1.3.4/Sources/main.swift")), [])
    }

    func testFindsSeveralAppsAndNamesThem() {
        let found = ArchivedApps.find(in: entries(app("B.app"), app("A Uygulama.app")))
        XCTAssertEqual(found.map(\.name), ["A Uygulama", "B"])
        XCTAssertEqual(found[0].fileName, "A Uygulama.app")
        XCTAssertEqual(found[1].plistPath, "B.app/Contents/Info.plist")
        XCTAssertEqual(found[1].resourcePath("AppIcon.icns"), "B.app/Contents/Resources/AppIcon.icns")
    }

    func testReadsBundleInfo() throws {
        let plist: [String: Any] = ["CFBundleName": "Kısa", "CFBundleDisplayName": "Uzun Ad", "CFBundleShortVersionString": "1.3.4",
                                    "CFBundleIdentifier": "local.x", "CFBundleIconFile": "AppIcon"]
        let info = try XCTUnwrap(AppBundleInfo(plist: PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)))
        XCTAssertEqual(info.name, "Uzun Ad")
        XCTAssertEqual(info.version, "1.3.4")
        XCTAssertEqual(info.identifier, "local.x")
        XCTAssertEqual(info.iconFileName, "AppIcon.icns")
        XCTAssertNil(AppBundleInfo(plist: Data("bozuk".utf8)))
    }

    // MARK: Denetim

    @discardableResult
    private func run(_ tool: String, _ args: String...) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    private func makeApp(_ name: String = "X.app", in folder: URL? = nil, version: String = "1.0", sign: Bool = true) throws -> URL {
        let url = (folder ?? tmp!).appendingPathComponent(name, isDirectory: true)
        let macos = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("X"))
        if !sign { _ = try run("/usr/bin/codesign", "--remove-signature", macos.appendingPathComponent("X").path) }
        let plist: [String: Any] = ["CFBundleIdentifier": "local.x", "CFBundleShortVersionString": version, "CFBundleExecutable": "X"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        if sign { XCTAssertEqual(try run("/usr/bin/codesign", "--force", "--sign", "-", url.path), 0) }
        return url
    }

    func testInspectAcceptsSignedApp() async throws {
        let result = try await AppInstaller.inspect(try makeApp())
        XCTAssertEqual(result.signature, .valid)
        XCTAssertEqual(result.info.version, "1.0")
    }

    func testInspectAcceptsUnsignedAppButSaysSo() async throws {
        let result = try await AppInstaller.inspect(try makeApp(sign: false))
        XCTAssertEqual(result.signature, .unsigned)
    }

    private func assertRefused(_ app: URL, _ expected: AppInstaller.Failure, line: UInt = #line) async {
        do {
            _ = try await AppInstaller.inspect(app)
            XCTFail("kabul edildi", line: line)
        } catch {
            XCTAssertEqual(error as? AppInstaller.Failure, expected, line: line)
        }
    }

    func testInspectRefusesTamperedApp() async throws {
        let app = try makeApp()
        try Data("kurcalandı".utf8).write(to: app.appendingPathComponent("Contents/MacOS/X"))
        await assertRefused(app, .brokenSignature)
    }

    func testInspectRefusesFolderWithoutInfo() async throws {
        let folder = tmp.appendingPathComponent("Y.app", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        await assertRefused(folder, .notAnApp)
    }

    func testLinksMustStayInsideTheBundle() throws {
        let app = try makeApp()
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: resources.appendingPathComponent("iyi").path, withDestinationPath: "../MacOS/X")
        XCTAssertNil(AppInstaller.unsafeLink(in: app))

        try fm.createSymbolicLink(atPath: resources.appendingPathComponent("disari").path, withDestinationPath: "../../../../etc")
        XCTAssertEqual(AppInstaller.unsafeLink(in: app), "Contents/Resources/disari")
        try fm.removeItem(at: resources.appendingPathComponent("disari"))

        try fm.createSymbolicLink(atPath: resources.appendingPathComponent("mutlak").path, withDestinationPath: "/etc/passwd")
        XCTAssertEqual(AppInstaller.unsafeLink(in: app), "Contents/Resources/mutlak")
    }

    func testQuarantineReachesEveryItem() throws {
        let app = try makeApp()
        let archive = tmp.appendingPathComponent("a.zip")
        try Data().write(to: archive)
        let value = Data("0081;00000000;Test;".utf8)
        Quarantine.apply(value, to: [archive])
        AppInstaller.applyQuarantine(from: archive, to: app)
        for url in [app, app.appendingPathComponent("Contents"), app.appendingPathComponent("Contents/MacOS/X")] {
            XCTAssertEqual(Quarantine.value(of: url), value, url.path)
        }
    }

    // MARK: Yerine koyma

    private var fakeTrash: (AppInstaller.Environment, URL) {
        let bin = tmp.appendingPathComponent("trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let env = AppInstaller.Environment(
            moveToTrash: { try FileManager.default.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent)) },
            runPrivileged: { _ in XCTFail("yönetici gerekmemeliydi") })
        return (env, bin)
    }

    private func version(_ app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")))?["CFBundleShortVersionString"] as? String
    }

    func testUniqueDestinationNeverOverwrites() throws {
        XCTAssertEqual(AppInstaller.uniqueDestination(for: "X.app", in: tmp).lastPathComponent, "X.app")
        _ = try makeApp()
        XCTAssertEqual(AppInstaller.uniqueDestination(for: "X.app", in: tmp).lastPathComponent, "X 2.app")
        _ = try makeApp("X 2.app")
        XCTAssertEqual(AppInstaller.uniqueDestination(for: "X.app", in: tmp).lastPathComponent, "X 3.app")
    }

    func testInstallIntoEmptyFolder() async throws {
        let source = try makeApp(version: "2.0")
        let apps = tmp.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let destination = apps.appendingPathComponent("X.app")
        try await AppInstaller.install(source, at: destination, environment: fakeTrash.0)
        XCTAssertEqual(version(destination), "2.0")
        XCTAssertFalse(fm.fileExists(atPath: source.path))
    }

    func testInstallMovesOldCopyToTrash() async throws {
        let apps = tmp.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let old = try makeApp(in: apps, version: "1.0")
        let source = try makeApp(version: "2.0")
        let (env, bin) = fakeTrash
        try await AppInstaller.install(source, at: old, environment: env)
        XCTAssertEqual(version(old), "2.0")
        XCTAssertEqual(version(bin.appendingPathComponent("X.app")), "1.0")
    }

    func testAsksForAdminWhenFolderIsNotWritable() async throws {
        let apps = tmp.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: apps.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: apps.path) }
        let source = try makeApp()
        let box = CommandBox()
        let env = AppInstaller.Environment(moveToTrash: { _ in XCTFail("yönetici yolu kullanılmalıydı") },
                                           runPrivileged: { box.set($0) })
        try await AppInstaller.install(source, at: apps.appendingPathComponent("X.app"), environment: env)
        XCTAssertTrue(box.value.contains("/bin/mv '\(source.path)'"), box.value)
        XCTAssertTrue(box.value.contains("chown -R \(getuid())"), box.value)
        XCTAssertTrue(fm.fileExists(atPath: source.path), "gerçekte taşınmadı")
    }

    func testCancelledAdminPromptChangesNothing() async throws {
        let apps = tmp.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: apps.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: apps.path) }
        let source = try makeApp()
        let env = AppInstaller.Environment(moveToTrash: { _ in }, runPrivileged: { _ in throw AppRemoval.RemovalError.cancelled })
        do {
            try await AppInstaller.install(source, at: apps.appendingPathComponent("X.app"), environment: env)
            XCTFail("iptal edilmeliydi")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testPrivilegedCommandOrderAndQuoting() {
        let cmd = AppInstaller.privilegedCommand(app: URL(fileURLWithPath: "/tmp/a'b/X.app"), destination: URL(fileURLWithPath: "/Applications/X.app"),
                                                 trash: URL(fileURLWithPath: "/Users/u/.Trash/X.app"), userID: 501)
        XCTAssertEqual(cmd, #"/bin/mv '/Applications/X.app' '/Users/u/.Trash/X.app' && /bin/mv '/tmp/a'\''b/X.app' '/Applications/X.app' && /usr/sbin/chown -R 501 '/Applications/X.app'"#)
    }
}

private final class CommandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String { lock.withLock { stored } }
    func set(_ text: String) { lock.withLock { stored = text } }
}
