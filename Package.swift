// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FastRecord",
    platforms: [
        .macOS(.v13) // ScreenCaptureKit需要macOS 12.3+，我们设置13以获得更好的SwiftUI支持
    ],
    products: [
        .executable(
            name: "FastRecord",
            targets: ["FastRecord"]
        ),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "FastRecord",
            dependencies: [],
            path: "ScreenRecorder",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)