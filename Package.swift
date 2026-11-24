// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CleanTrash",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "CleanTrashCore", targets: ["CleanTrashCore"]),
        .executable(name: "CleanTrash", targets: ["CleanTrashApp"]),
        .executable(name: "cleantrash-hook", targets: ["CleanTrashHook"])
    ],
    targets: [
        .target(
            name: "CleanTrashCore",
            path: "Sources/CleanTrashCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("LocalAuthentication")
            ]
        ),
        .executableTarget(
            name: "CleanTrashApp",
            dependencies: ["CleanTrashCore"],
            path: "Sources/CleanTrashApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Charts"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "CleanTrashHook",
            dependencies: ["CleanTrashCore"],
            path: "Sources/CleanTrashHook"
        ),
        .testTarget(
            name: "CleanTrashCoreTests",
            dependencies: ["CleanTrashCore"],
            path: "Tests/CleanTrashCoreTests"
        )
    ]
)
