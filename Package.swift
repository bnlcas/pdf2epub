// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "pdf2epub",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "pdf2epub", targets: ["pdf2epub"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "pdf2epub",
            dependencies: [
                "PDF2EPUBCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "PDF2EPUBCore"),
        .testTarget(
            name: "PDF2EPUBCoreTests",
            dependencies: ["PDF2EPUBCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
