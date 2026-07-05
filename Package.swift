// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "viterm",
    platforms: [.macOS(.v15)],
    targets: [
        // ドメインモデル・設定(UI非依存)
        .target(name: "VitermCore"),
        .testTarget(name: "VitermCoreTests", dependencies: ["VitermCore"]),
        // git CLI ラッパー(UI非依存)
        .target(name: "GitKit"),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
        // ドメイン+git を束ねるサービス層(UI非依存)
        .target(name: "VitermServices", dependencies: ["VitermCore", "GitKit"]),
        .testTarget(name: "VitermServicesTests", dependencies: ["VitermServices"]),
        // libghostty (scripts/build-ghostty.sh で生成。vendor/ は git 管理外)
        .binaryTarget(name: "GhosttyKit", path: "vendor/ghostty/macos/GhosttyKit.xcframework"),
        // AppKit アプリ本体
        .executableTarget(
            name: "VitermApp",
            dependencies: ["VitermCore", "GitKit", "VitermServices", "GhosttyKit"],
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
)
