// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Searoom",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Searoom", targets: ["Searoom"])
    ],
    targets: [
        .executableTarget(
            name: "Searoom",
            dependencies: ["CSearoomSensors"],
            path: "Sources/Searoom",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal")
            ]
        ),
        .target(
            name: "CSearoomSensors",
            path: "Sources/CSearoomSensors",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "SearoomTests",
            dependencies: ["Searoom"],
            path: "Tests/SearoomTests"
        )
    ]
)
