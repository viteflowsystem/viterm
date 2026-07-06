// swift-tools-version: 6.0
import Foundation
import PackageDescription

// UI 非依存ターゲット(+テスト)。CI はこれだけをビルド・テストする。
var targets: [Target] = [
    // ドメインモデル・設定(UI非依存)
    .target(name: "VitermCore", resources: [.process("Resources")]),
    .testTarget(name: "VitermCoreTests", dependencies: ["VitermCore"]),
    // git CLI ラッパー(UI非依存)
    .target(name: "GitKit"),
    .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
    // ドメイン+git を束ねるサービス層(UI非依存)
    .target(name: "VitermServices", dependencies: ["VitermCore", "GitKit"], resources: [.process("Resources")]),
    .testTarget(name: "VitermServicesTests", dependencies: ["VitermServices"]),
]

// アプリ本体は libghostty(scripts/build-ghostty.sh で生成する xcframework)を要求する。
// CI ではこの生成をスキップしたいので、`VITERM_CORE_ONLY=1` のときアプリターゲットを外す
// (`swift test` は executable も含む全ターゲットをビルドするため、これが無いと
// xcframework の無い環境でテストすら走らない)。
if ProcessInfo.processInfo.environment["VITERM_CORE_ONLY"] == nil {
    targets += [
        // libghostty (scripts/build-ghostty.sh で生成。vendor/ は git 管理外)
        .binaryTarget(name: "GhosttyKit", path: "vendor/ghostty/macos/GhosttyKit.xcframework"),
        // AppKit アプリ本体
        .executableTarget(
            name: "VitermApp",
            dependencies: ["VitermCore", "GitKit", "VitermServices", "GhosttyKit"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedLibrary("stdc++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
}

let package = Package(
    name: "viterm",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: targets
)
