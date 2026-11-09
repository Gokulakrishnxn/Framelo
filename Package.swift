// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Framelo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FrameloCore", targets: ["FrameloCore"]),
        .executable(name: "Framelo", targets: ["Framelo"]),
    ],
    targets: [
        .target(name: "FrameloCore", path: "Sources/FrameloCore"),
        .executableTarget(name: "Framelo", dependencies: ["FrameloCore"], path: "Sources/Framelo"),
        .testTarget(name: "FrameloTests", dependencies: ["FrameloCore"], path: "Tests/FrameloTests"),
    ],
    swiftLanguageModes: [.v6]
)
