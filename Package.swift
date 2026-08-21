// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MrTab",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MrTab",
            path: "Sources/MrTab",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
