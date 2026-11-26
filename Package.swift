// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "JottaFS",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "JottaFSCore", targets: ["JottaFSCore"]),
        .executable(name: "jottafs-checks", targets: ["JottaFSCoreChecks"]),
        .executable(name: "jottafs-fskit-module", targets: ["JottaFSKitExtension"])
    ],
    targets: [
        .target(
            name: "JottaFSCore",
            path: "Sources/JottaFSCore",
            // Translations are bundled by the Xcode project only.
            exclude: ["Localizable.xcstrings"]
        ),
        .executableTarget(
            name: "JottaFSCoreChecks",
            dependencies: ["JottaFSCore"],
            path: "Tests/JottaFSCoreChecks"
        ),
        .executableTarget(
            name: "JottaFSKitExtension",
            dependencies: ["JottaFSCore"],
            path: "Sources/JottaFSKitExtension"
        ),
        .testTarget(
            name: "JottaFSCoreTests",
            dependencies: ["JottaFSCore"],
            path: "Tests/JottaFSCoreTests"
        ),
        .testTarget(
            name: "JottaFSKitExtensionTests",
            dependencies: ["JottaFSKitExtension", "JottaFSCore"],
            path: "Tests/JottaFSKitExtensionTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
