// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TaskMaster",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "TaskMaster",
            path: "Sources/TaskMaster",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Metal"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
