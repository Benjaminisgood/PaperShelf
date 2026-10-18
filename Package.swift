// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperShelf",
    platforms: [.macOS("27.0")],
    products: [.library(name: "PaperCore", targets: ["PaperCore"]), .executable(name: "PaperShelf", targets: ["PaperShelf"]), .executable(name: "PaperShelfCLI", targets: ["PaperShelfCLI"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PaperCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PaperShelf", dependencies: ["PaperCore"]),
        .executableTarget(name: "PaperShelfCLI", dependencies: ["PaperCore"]),
        .testTarget(name: "PaperCoreTests", dependencies: ["PaperCore"])
    ],
    swiftLanguageModes: [.v5]
)
