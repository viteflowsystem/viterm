// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vitea",
    platforms: [.macOS(.v15)],
    targets: [
        // ドメインモデル・設定(UI非依存)
        .target(name: "ViteaCore"),
        .testTarget(name: "ViteaCoreTests", dependencies: ["ViteaCore"]),
        // git CLI ラッパー(UI非依存)
        .target(name: "GitKit"),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        // ドメイン+git を束ねるサービス層(UI非依存)
        .target(name: "ViteaServices", dependencies: ["ViteaCore", "GitKit"]),
        .testTarget(name: "ViteaServicesTests", dependencies: ["ViteaServices"]),
        // AppKit アプリ本体
        .executableTarget(name: "ViteaApp", dependencies: ["ViteaCore", "GitKit", "ViteaServices"]),
    ]
)
