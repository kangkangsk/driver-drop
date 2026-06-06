// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DriveDropSwiftUI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DriveDrop", targets: ["DriveDrop"])
    ],
    targets: [
        .executableTarget(name: "DriveDrop")
    ]
)
