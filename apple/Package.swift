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
        // NOTE: Singbox.xcframework (sing-box / "Speed" mode) is built by a
        // dedicated CI job (build-singbox.yml). Once that job is green, add
        // it back as a binaryTarget + dependency here to link it into the app:
        //   .binaryTarget(name: "Singbox", path: "Frameworks/Singbox.xcframework"),
        // and add `.target(name: "Singbox", condition: .when(platforms: [.iOS]))`
        // to ZanozaKit's dependencies. Until then VlessEngine compiles via
        // `#if canImport(Singbox)` and reports "engine not embedded".
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
