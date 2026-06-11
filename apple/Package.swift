// swift-tools-version: 5.9

import PackageDescription

// The Mobile.xcframework must be built before resolving this package.
// Generate it via: apple/Scripts/build-xcframework.sh
let package = Package(
    name: "ZanozaApple",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ZanozaKit", targets: ["ZanozaKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "Mobile",
            path: "Frameworks/Mobile.xcframework"
        ),
        // NOTE: Singbox.xcframework (sing-box) is currently NOT linked into the
        // app — "Speed" mode is handed off to the Happ client instead, so the
        // in-app VLESS engine is unused. The Go module + build-singbox CI job
        // remain in the repo; to re-enable in-app VLESS (e.g. once a paid
        // Apple account + Network Extension exist), re-add:
        //   .binaryTarget(name: "Singbox", path: "Frameworks/Singbox.xcframework"),
        // and the `.target(name: "Singbox", ...)` dependency below, plus
        // OTHER_LDFLAGS = -lresolv in project.yml.
        .target(
            name: "ZanozaKit",
            dependencies: [
                .target(name: "Mobile", condition: .when(platforms: [.iOS])),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "ZanozaKitTests",
            dependencies: ["ZanozaKit"]
        ),
    ]
)
