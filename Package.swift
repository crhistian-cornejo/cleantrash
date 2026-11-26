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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
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
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "CleanTrashApp",
            dependencies: ["CleanTrashCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/CleanTrashApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Charts"),
                .linkedFramework("IOKit"),
                .linkedFramework("Vision"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Translation"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
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
