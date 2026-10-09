// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LeaveMyMacAlone",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .target(
            name: "LeaveMyMacAloneCore"
        ),
        .executableTarget(
            name: "LeaveMyMacAlone",
            dependencies: [
                "LeaveMyMacAloneCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                // bundle.sh embeds Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("CoreImage")
            ]
        ),
        .testTarget(
            name: "LeaveMyMacAloneTests",
            dependencies: ["LeaveMyMacAloneCore", "LeaveMyMacAlone"]
        )
    ]
)
