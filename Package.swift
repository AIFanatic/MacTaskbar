// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacTaskbar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacTaskbar",
            path: "Sources",
            sources: ["main.swift"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        )
    ]
)
