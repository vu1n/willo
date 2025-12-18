// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WilloPkg",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WilloPkg",
            targets: ["WilloPkg"]
        ),
    ],
    dependencies: [
        // NIOSSH for SSH connections (replacing Citadel)
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "WilloPkg",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                "willo",
                "mosh",
                "Protobuf_C_",
            ],
            path: "Sources",
            resources: [
                .copy("Resources/Fonts"),
                .process("Renderer/TerminalShaders.metal")
            ]
        ),
        .binaryTarget(
            name: "willo",
            path: "Frameworks/willo.xcframework"
        ),
        .binaryTarget(
            name: "mosh",
            path: "Frameworks/mosh.xcframework"
        ),
        .binaryTarget(
            name: "Protobuf_C_",
            path: "Frameworks/Protobuf_C_.xcframework"
        ),
        .testTarget(
            name: "WilloPkgTests",
            dependencies: ["WilloPkg"],
            path: "Tests"
        ),
    ]
)
