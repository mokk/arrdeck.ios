// swift-tools-version: 6.0

// ArrdeckKit is everything the app does that is not a screen: profiles, the
// backend probe, capability handling, storage. It is deliberately buildable on
// macOS so `swift test` runs on a machine with only Command Line Tools — the
// Xcode app target (App/) merely consumes it.
//
// ArrdeckAPI is the generated client: swift-openapi-generator runs as a build
// plugin over the committed spec in the arrdeck submodule (symlinked into the
// target), so the 125 routes are typed and drift from the pinned backend is a
// compile error rather than a runtime surprise.
import PackageDescription

let package = Package(
    name: "arrdeck-ios",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ArrdeckKit", targets: ["ArrdeckKit"]),
        .library(name: "ArrdeckAPI", targets: ["ArrdeckAPI"]),
        .library(name: "ArrdeckUI", targets: ["ArrdeckUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
    ],
    targets: [
        .target(name: "ArrdeckKit"),
        .target(
            name: "ArrdeckAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        // Views compile against the macOS SDK too, so type errors surface from
        // `swift build` without Xcode. iOS-only API stays out of this target.
        .target(name: "ArrdeckUI", dependencies: ["ArrdeckKit"]),
        .testTarget(
            name: "ArrdeckKitTests",
            dependencies: ["ArrdeckKit", "ArrdeckAPI"]
        ),
    ]
)
