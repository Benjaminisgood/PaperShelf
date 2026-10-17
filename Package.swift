// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperShelf",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PaperCore", targets: ["PaperCore"]), .executable(name: "PaperShelf", targets: ["PaperShelf"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PaperCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PaperShelf", dependencies: ["PaperCore"]),
        .testTarget(name: "PaperCoreTests", dependencies: ["PaperCore"])
    ],
    swiftLanguageModes: [.v5]
)
