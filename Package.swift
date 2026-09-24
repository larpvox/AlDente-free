// swift-tools-version:5.7
//
// For `swift build`, Xcode and SourceKit-LSP. The shipping app is built by
// ./make.sh, which also produces the universal binary and the .app bundle.

import PackageDescription

let package = Package(
    name: "BatteryScope",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BatteryScope", targets: ["BatteryScope"]),
    ],
    targets: [
        .executableTarget(
            name: "BatteryScope",
            path: "Sources/BatteryScope",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)
