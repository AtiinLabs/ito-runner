// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ito-runner",
    platforms: [
        .macOS(.v14), .iOS(.v15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ito-runner",
            targets: ["ito-runner"]
        )
    ],
    dependencies: [
        // AtiinLabs fork of WasmKit; its fixes (e.g. iOS 15 builds) are not tagged.
        .package(
            url: "https://github.com/AtiinLabs/WasmKit.git",
            revision: "c76d7ea351c10480c6473ab522fdc1b622ed9432"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0"))
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "ito-runner",
            dependencies: [
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .testTarget(
            name: "ito-runnerTests",
            dependencies: [
                "ito-runner",
                .product(name: "WAT", package: "WasmKit")
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
