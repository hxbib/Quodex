// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Quodex",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Quodex", targets: ["Quodex"]),
    ],
    targets: [
        .executableTarget(
            name: "Quodex",
            path: "Sources/Quodex"
        ),
    ]
)
