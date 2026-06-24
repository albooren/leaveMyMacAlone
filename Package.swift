// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LeaveMyMacAlone",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "LeaveMyMacAloneCore"
        ),
        .executableTarget(
            name: "LeaveMyMacAlone",
            dependencies: ["LeaveMyMacAloneCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "LeaveMyMacAloneTests",
            dependencies: ["LeaveMyMacAloneCore"]
        )
    ]
)
