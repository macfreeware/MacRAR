import XCTest
@testable import MacRARCore

final class AppRemovalTests: XCTestCase {
    private var root: URL!
    private var apps: URL!
    private var support: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-removal-\(UUID().uuidString)")
        apps = root.appendingPathComponent("Applications", isDirectory: true)
        support = root.appendingPathComponent("Support/MacRAR", isDirectory: true)
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("MacRAR.app/Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("tools/rar"), withIntermediateDirectories: true)
        try "tok".write(to: support.appendingPathComponent("finder.token"), atomically: true, encoding: .utf8)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func env(log: Log, receipt: Bool = false, privilegedError: Error? = nil) -> AppRemoval.Environment {
        let apps = self.apps!, support = self.support!
        return AppRemoval.Environment(
            appParents: [apps], supportDirectory: support,
            clearDefaults: { log.add("defaults") },
            receiptExists: { receipt },
            runPrivileged: { command in
                log.add("sudo:\(command)")
                if let privilegedError { throw privilegedError }
                // Gerçekte rm -rf yönetici yetkisiyle çalışır; testte uygulamayı biz sileriz.
                try FileManager.default.removeItem(at: apps.appendingPathComponent("MacRAR.app"))
            },
            runTool: { path, args in log.add("\((path as NSString).lastPathComponent) \(args.joined(separator: " "))"); return 0 },
            scheduleFinalCleanup: { log.add("final:\($0)") })
    }

    func testOnlyMacRARAppInApplicationsIsRemovable() {
        let parents = [apps!]
        XCTAssertNotNil(AppRemoval.removableApp(bundleURL: apps.appendingPathComponent("MacRAR.app"), parents: parents))
        XCTAssertNil(AppRemoval.removableApp(bundleURL: apps.appendingPathComponent("Baska.app"), parents: parents))
        XCTAssertNil(AppRemoval.removableApp(bundleURL: root.appendingPathComponent("build/MacRAR.app"), parents: parents),
                     "Uygulamalar dışındaki geliştirme kopyası silinmemeli")
        XCTAssertNil(AppRemoval.removableApp(bundleURL: apps, parents: parents))
    }

    func testQuotingIsSafe() {
        XCTAssertEqual(AppRemoval.shellQuote("/Applications/MacRAR.app"), "'/Applications/MacRAR.app'")
        XCTAssertEqual(AppRemoval.shellQuote("a'b"), #"'a'\''b'"#)
        XCTAssertEqual(AppRemoval.appleScriptEscape(#"say "hi" \ x"#), #"say \"hi\" \\ x"#)
        let c = AppRemoval.privilegedCommand(appPath: "/Applications/MacRAR.app", forgetReceipt: true)
        XCTAssertTrue(c.hasPrefix("/bin/rm -rf '/Applications/MacRAR.app'") && c.contains("pkgutil --forget local.macrar.pkg"))
        XCTAssertFalse(AppRemoval.privilegedCommand(appPath: "/Applications/MacRAR.app", forgetReceipt: false).contains("pkgutil"))
    }

    func testFullRemovalWithPackageReceiptUsesAdminAndCleansEverything() async throws {
        let log = Log()
        let report = try await AppRemoval.remove(bundleURL: apps.appendingPathComponent("MacRAR.app"),
                                                 options: .init(removeUserData: true, removePasswords: true),
                                                 environment: env(log: log, receipt: true))
        XCTAssertTrue(report.appRemoved && report.userDataRemoved && report.passwordsRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: apps.appendingPathComponent("MacRAR.app").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path), "ayarlar ve araçlar silinmeli")
        let entries = log.all
        XCTAssertTrue(entries.first?.hasPrefix("sudo:") == true, "yönetici adımı en önce olmalı: \(entries)")
        XCTAssertTrue(entries.contains { $0.contains("pluginkit -e ignore -i local.macrar.app.FinderSync") })
        XCTAssertTrue(entries.contains { $0.contains("security delete-generic-password -s local.macrar.password-manager") })
        XCTAssertTrue(entries.contains("defaults") && entries.last == "final:true")
    }

    func testPasswordsAndDataAreKeptUnlessRequested() async throws {
        let log = Log()
        let report = try await AppRemoval.remove(bundleURL: apps.appendingPathComponent("MacRAR.app"),
                                                 options: .init(removeUserData: false, removePasswords: false),
                                                 environment: env(log: log, receipt: false))
        XCTAssertTrue(report.appRemoved)
        XCTAssertFalse(report.userDataRemoved || report.passwordsRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("finder.token").path))
        XCTAssertFalse(log.all.contains { $0.contains("security") || $0 == "defaults" })
        XCTAssertEqual(log.all.last, "final:false")
        // Alıcı yok ve dosya kullanıcıya ait: yönetici istenmemeli.
        XCTAssertFalse(log.all.contains { $0.hasPrefix("sudo:") })
    }

    func testCancelledAdminPromptChangesNothing() async throws {
        let log = Log()
        do {
            _ = try await AppRemoval.remove(bundleURL: apps.appendingPathComponent("MacRAR.app"),
                                            options: .init(removeUserData: true, removePasswords: true),
                                            environment: env(log: log, receipt: true, privilegedError: AppRemoval.RemovalError.cancelled))
            XCTFail("iptal hata olarak dönmeli")
        } catch { XCTAssertEqual(error as? AppRemoval.RemovalError, .cancelled) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: apps.appendingPathComponent("MacRAR.app").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("finder.token").path))
        XCTAssertEqual(log.all.filter { !$0.hasPrefix("sudo:") }, [], "iptalde başka hiçbir adım çalışmamalı")
    }

    func testDevelopmentCopyOutsideApplicationsOnlyCleansData() async throws {
        let dev = root.appendingPathComponent("build/MacRAR.app")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        let log = Log()
        let report = try await AppRemoval.remove(bundleURL: dev, options: .init(removeUserData: true, removePasswords: false),
                                                 environment: env(log: log))
        XCTAssertFalse(report.appRemoved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dev.path), "geliştirme kopyasına dokunulmamalı")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(log.all.contains { $0.hasPrefix("sudo:") })
    }
}
