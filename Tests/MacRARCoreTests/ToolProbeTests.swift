import XCTest
@testable import MacRARCore

final class ToolProbeTests: XCTestCase {
    func testParseVersions() {
        XCTAssertEqual(ToolProbe.parseVersion("\nUNRAR 6.24 freeware      Copyright (c) 1993-2023 Alexander Roshal\n"), "6.24")
        XCTAssertEqual(ToolProbe.parseVersion("\nRAR 6.24   Copyright (c) 1993-2023 Alexander Roshal   3 Oct 2023\nRegistered to X\n"), "6.24")
        XCTAssertEqual(ToolProbe.parseVersion("bsdtar 3.7.4 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3"), "3.7.4")
        XCTAssertEqual(ToolProbe.parseVersion("v1.10.7"), "1.10.7", "unar -version")
        XCTAssertNil(ToolProbe.parseVersion("hiç sürüm yok"))
        XCTAssertNil(ToolProbe.parseVersion(""))
    }

    func testVersionDisplay() {
        XCTAssertEqual(VersionInfo(version: "1.0", build: "12", commit: "28071c6").display, "Sürüm 1.0 (derleme 12 · 28071c6)")
        XCTAssertEqual(VersionInfo(version: "1.0", build: "12", commit: nil).display, "Sürüm 1.0 (derleme 12)")
        XCTAssertEqual(VersionInfo(version: "2.1", build: nil, commit: nil).display, "Sürüm 2.1")
        XCTAssertEqual(VersionInfo(version: nil, build: nil, commit: nil).display, "Geliştirme derlemesi")
    }

    func testRealToolVersionsWhenInstalled() async throws {
        let tools = TestTools.paths()
        if let bsdtar = tools.bsdtar {
            let v = await ToolProbe.version(of: bsdtar, arguments: ["--version"])
            XCTAssertNotNil(v, "bsdtar sürümü okunmalı")
        }
        if let unrar = tools.unrar {
            let v = await ToolProbe.version(of: unrar)
            XCTAssertNotNil(v, "unrar sürümü okunmalı")
        }
    }
}
