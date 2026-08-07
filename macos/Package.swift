// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IOSCPYDream",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ioscpy-dream", targets: ["IOSCPYDream"]),
    ],
    targets: [
        .executableTarget(
            name: "IOSCPYDream",
            path: "Sources/IOSCPYDream",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("MetalKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Network"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
