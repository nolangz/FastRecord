// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FastRecord",
    platforms: [
        .macOS(.v13) // ScreenCaptureKit 需要 macOS 12.3+；macOS 26 通过签名 .app 包适配权限/TCC 行为
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