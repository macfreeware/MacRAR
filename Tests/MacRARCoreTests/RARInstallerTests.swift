import XCTest
@testable import MacRARCore

final class RARInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private let page = """
    <a href="/rar/rarmacos-arm-722.tar.gz">old</a>
    <a href="/rar/rarmacos-arm-723.tar.gz">RAR 7.23 arm</a>
    <a href="/rar/rarmacos-arm-730b1.tar.gz">beta</a>
    <a href="/rar/rarmacos-x64-723.tar.gz">RAR 7.23 x64</a>
    <a href="/rar/rarmacos-x64-730b1.tar.gz">beta</a>
    """

    /// Sahte (betik) rar/unrar içeren, gerçek pakete benzeyen bir tar.gz üretir.
    private func makePackage(rarBanner: String = "RAR 7.23   Copyright (c) 1993-2026 Alexander Roshal") throws -> URL {
        let dir = root.appendingPathComponent("pkg/rar", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String, exec: Bool) throws {
            let url = dir.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: exec ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        try write("rar", "#!/bin/sh\necho\necho '\(rarBanner)'\n", exec: true)
        try write("unrar", "#!/bin/sh\necho\necho 'UNRAR 7.23 freeware      Copyright (c) 1993-2026 Alexander Roshal'\n", exec: true)
        try write("license.txt", "licence", exec: false)
        try write("default.sfx", "sfx", exec: false)
        try write("rarfiles.lst", "lst", exec: false)
        let out = root.appendingPathComponent("rar.tar.gz")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", out.path, "-C", root.appendingPathComponent("pkg").path, "rar"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return out
    }

    private func fetcher(page: String, package: URL?, onDownload: (@Sendable (URL) -> Void)? = nil) -> RARInstaller.Fetcher {
        RARInstaller.Fetcher(
            page: { _ in page },
            download: { url, dest in
                onDownload?(url)
                guard let package else { throw RARInstaller.InstallError.download("yok") }
                try FileManager.default.copyItem(at: package, to: dest)
            })
    }

    func testParsePicksNewestStableForArchitecture() throws {
        let arm = try XCTUnwrap(RARInstaller.parsePackage(html: page, arch: "arm"))
        XCTAssertEqual(arm.version, "7.23")
        XCTAssertEqual(arm.url.absoluteString, "https://www.rarlab.com/rar/rarmacos-arm-723.tar.gz")
        let x64 = try XCTUnwrap(RARInstaller.parsePackage(html: page, arch: "x64"))
        XCTAssertEqual(x64.url.lastPathComponent, "rarmacos-x64-723.tar.gz")
        XCTAssertNil(RARInstaller.parsePackage(html: "<html></html>", arch: "arm"))
        XCTAssertEqual(RARInstaller.formatVersion("723"), "7.23")
        XCTAssertEqual(RARInstaller.formatVersion("1010"), "1.010")
    }

    func testInstallsVerifiedToolsWithoutAdminAndReplacesOldInstall() async throws {
        let package = try makePackage()
        let dest = root.appendingPathComponent("tools/rar")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "eski".write(to: dest.appendingPathComponent("eski.txt"), atomically: true, encoding: .utf8)

        let steps = LockedBox<[String]>([])
        let installed = try await RARInstaller.install(fetcher: fetcher(page: page, package: package),
                                                       destination: dest, arch: "arm",
                                                       progress: { text in steps.mutate { $0.append(text) } })
        XCTAssertEqual(installed.version, "7.23")
        for name in ["rar", "unrar"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.appendingPathComponent(name).path), name)
        }
        for name in ["license.txt", "default.sfx", "rarfiles.lst"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent(name).path), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("eski.txt").path), "eski kurulum değiştirilmeli")
        XCTAssertTrue(steps.value.contains { $0.contains("indiriliyor") } && steps.value.last?.contains("kuruldu") == true)
        // Kurulan araç gerçekten çalışır ve ToolPaths tarafından bulunur.
        XCTAssertEqual(ToolPaths.find("rar", override: dest.appendingPathComponent("rar").path)?.lastPathComponent, "rar")
        // Geçici dosyalar ve hazırlık klasörleri geride kalmamalı.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["rar"])
    }

    func testRejectsPackageFromOtherHostWithoutDownloading() async throws {
        let evil = #"<a href="https://evil.example/rar/rarmacos-arm-723.tar.gz">x</a>"#
        let downloaded = LockedBox(false)
        let package = try makePackage()
        do {
            _ = try await RARInstaller.install(fetcher: fetcher(page: evil, package: package, onDownload: { _ in downloaded.mutate { $0 = true } }),
                                               destination: root.appendingPathComponent("d/rar"), arch: "arm")
            XCTFail("güvenilmeyen adres reddedilmeli")
        } catch let e as RARInstaller.InstallError {
            guard case .untrustedURL = e else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(downloaded.value)
        let http = #"<a href="http://www.rarlab.com/rar/rarmacos-arm-723.tar.gz">x</a>"#
        do {
            _ = try await RARInstaller.install(fetcher: fetcher(page: http, package: package),
                                               destination: root.appendingPathComponent("d/rar"), arch: "arm")
            XCTFail("düz http reddedilmeli")
        } catch let e as RARInstaller.InstallError {
            guard case .untrustedURL = e else { return XCTFail("\(e)") }
        }
    }

    func testBrokenToolIsNotInstalled() async throws {
        let package = try makePackage(rarBanner: "bu rar degil")
        let dest = root.appendingPathComponent("d/rar")
        do {
            _ = try await RARInstaller.install(fetcher: fetcher(page: page, package: package), destination: dest, arch: "arm")
            XCTFail("doğrulama başarısız olmalı")
        } catch let e as RARInstaller.InstallError {
            guard case .verification = e else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testPageAndDownloadFailuresAreReported() async throws {
        let dest = root.appendingPathComponent("d/rar")
        do {
            _ = try await RARInstaller.install(fetcher: fetcher(page: "<html></html>", package: nil), destination: dest, arch: "arm")
            XCTFail()
        } catch { XCTAssertEqual(error as? RARInstaller.InstallError, .noPackage) }
        do {
            _ = try await RARInstaller.install(fetcher: fetcher(page: page, package: nil), destination: dest, arch: "arm")
            XCTFail()
        } catch let e as RARInstaller.InstallError {
            guard case .download = e else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }
}

/// Eşzamanlı kapanışlardan güvenle yazılabilen basit kutu (Sendable).
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&stored) }
}

/// Gerçek RARLAB sitesiyle uçtan uca deneme (ağ gerekir): MACRAR_TEST_LIVE=1 swift test --filter RARInstallerLiveTests
final class RARInstallerLiveTests: XCTestCase {
    func testLiveDownloadInstallsWorkingRar() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACRAR_TEST_LIVE"] == "1", "ağ testi (MACRAR_TEST_LIVE=1)")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-live-\(UUID().uuidString)/rar")
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }
        let installed = try await RARInstaller.install(destination: dest)
        print("LIVE sürüm:", installed.version)
        let r = try await ProcessRunner.run(dest.appendingPathComponent("rar"), [])
        XCTAssertTrue(r.text.contains("RAR \(installed.version)"), r.text)
        let u = try await ProcessRunner.run(dest.appendingPathComponent("unrar"), [])
        XCTAssertTrue(u.text.contains("UNRAR \(installed.version)"), u.text)
    }
}
