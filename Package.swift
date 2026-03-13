// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AsyncFlow",
    platforms: [.iOS(.v15), .macOS(.v13), .tvOS(.v15), .watchOS(.v8)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "AsyncFlow",
            targets: ["AsyncFlow"]
        ),
        .library(
            name: "AsyncFlowTestUtilities",
            targets: ["AsyncFlowTestUtilities"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "AsyncFlow"
        ),
        .target(
            name: "AsyncFlowTestUtilities",
            dependencies: ["AsyncFlow"]
        ),
        .testTarget(
            name: "AsyncFlowTests",
            dependencies: ["AsyncFlow", "AsyncFlowTestUtilities"]
        ),
    ]
)
