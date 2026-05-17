// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConvStack",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ConvStackApp", targets: ["ConvStackApp"])
    ],
    targets: [
        .executableTarget(
            name: "ConvStackApp",
            path: "Sources/ConvStackApp"
        )
    ]
)
