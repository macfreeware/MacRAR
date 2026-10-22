// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacRAR",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "MacRAR", targets: ["MacRAR"]),
    ],
    targets: [
        // UI'dan bağımsız çekirdek: rar/unrar/bsdtar komutlarını çalıştırır ve çıktılarını ayrıştırır.
        .target(name: "MacRARCore"),
        // SwiftUI arayüzü.
        .executableTarget(name: "MacRAR", dependencies: ["MacRARCore"]),
        .testTarget(name: "MacRARCoreTests", dependencies: ["MacRARCore"]),
        .testTarget(name: "MacRARTests", dependencies: ["MacRAR", "MacRARCore"]),
    ]
)
