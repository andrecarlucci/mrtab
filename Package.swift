// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mrtab",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "mrtab",
            path: "Sources/mrtab",
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
