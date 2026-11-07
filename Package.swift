// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Suyoi",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Suyoi", targets: ["SuyoiApp"]), .library(name: "SuyoiCore", targets: ["SuyoiCore"])],
    targets: [.target(name: "SuyoiCore"), .executableTarget(name: "SuyoiApp", dependencies: ["SuyoiCore"]), .testTarget(name: "SuyoiCoreTests", dependencies: ["SuyoiCore"])],
    swiftLanguageModes: [.v5]
)
