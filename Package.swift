// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-s3m",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftS3M", targets: ["SwiftS3M"])
    ],
    targets: [
        .target(name: "SwiftS3M"),
        .testTarget(name: "SwiftS3MTests", dependencies: ["SwiftS3M"])
    ]
)
