// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "codexStack",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "codexStack", targets: ["codexStack"])
    ],
    targets: [
        .executableTarget(
            name: "codexStack",
            path: "Sources/codexStack",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/codexStack/Info.plist"
                ])
            ]
        )
    ]
)
