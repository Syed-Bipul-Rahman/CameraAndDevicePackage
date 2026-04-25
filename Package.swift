// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Supernova",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "Supernova", targets: ["Supernova"])
    ],
    targets: [
        .target(
            name: "Supernova",
            path: "Sources/Supernova"
        )
    ]
)
