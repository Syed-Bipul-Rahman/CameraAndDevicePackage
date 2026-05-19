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
            path: "Sources/Supernova",
            resources: [
                // .mlmodelc is a compiled-model directory bundle. .process() walks into it and the inner
                // coremldata.bin files at /, /analytics, and /neural_network_optionals collide in the
                // bundle's flat resource namespace. Use .copy() to drop it in verbatim, structure intact.
                .copy("Resources/FaceParsing.mlmodelc"),
                .process("Resources/tut1.jpg"),
                .process("Resources/tut2.jpg"),
                .process("Resources/tut3.jpg"),
                .process("Resources/beautyfilterIcon.png"),
                .process("Resources/kissfilterIcon.png"),
                .process("Resources/retouchfilterIcon.png")
            ]
        )
    ]
)
