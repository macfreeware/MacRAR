import Foundation
import MacRARCore

/// Testlerde kullanılacak araç yolları. MACRAR_TEST_RAR_DIR=<klasör> verilirse rar/unrar o klasörden alınır
/// (örn. başka bir RAR sürümüyle ya da resmi deneme sürümüyle sınamak için).
enum TestTools {
    static func paths() -> ToolPaths {
        var tools = ToolPaths.detect()
        if let dir = ProcessInfo.processInfo.environment["MACRAR_TEST_RAR_DIR"], !dir.isEmpty {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            tools.rar = base.appendingPathComponent("rar")
            tools.unrar = base.appendingPathComponent("unrar")
        }
        // MACRAR_TEST_UNAR_DIR=<klasör>: unar/lsar'ı o klasörden al. MACRAR_TEST_ONLY_UNAR=1: RAR için YALNIZCA unar
        // kullanılsın (rar/unrar yokmuş gibi) — unar yedek yolunu sınamak için.
        if let dir = ProcessInfo.processInfo.environment["MACRAR_TEST_UNAR_DIR"], !dir.isEmpty {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            tools.unar = base.appendingPathComponent("unar")
            tools.lsar = base.appendingPathComponent("lsar")
        }
        if ProcessInfo.processInfo.environment["MACRAR_TEST_ONLY_UNAR"] == "1" {
            tools.rar = nil
            tools.unrar = nil
        }
        return tools
    }
}
