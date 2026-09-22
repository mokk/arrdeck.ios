// swift-tools-version: 6.0

// ArrdeckKit is everything the app does that is not a screen: profiles, the
// backend probe, capability handling, storage. It is deliberately buildable on
// macOS so `swift test` runs on a machine with only Command Line Tools — the
// Xcode app target (App/) merely consumes it.
//
// ArrdeckAPI is the generated client: swift-openapi-generator runs as a build
// plugin over Sources/ArrdeckAPI/openapi.json, which Scripts/derive-spec.sh
// derives from the pinned submodule's spec (see Scripts/derive-spec.jq for the
// one rewrite it applies). The 125 routes are typed, and drift from the pinned
// backend is a compile error rather than a runtime surprise.
import PackageDescription

let package = Package(
    name: "arrdeck-ios",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ArrdeckKit", targets: ["ArrdeckKit"]),
        .library(name: "ArrdeckAPI", targets: ["ArrdeckAPI"]),
        .library(name: "ArrdeckData", targets: ["ArrdeckData"]),
        .library(name: "ArrdeckUI", targets: ["ArrdeckUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
        // Only for the tests' stub transport; the runtime already depends on it.
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
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
        // The screens' data layer: domain names over the generated types, the
        // ServiceBlock states every card renders, poll cadence, formatting and
        // the observable models. No SwiftUI, so all of it is unit-testable.
        .target(
            name: "ArrdeckData",
            dependencies: [
                "ArrdeckAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ]
        ),
        // Views compile against the macOS SDK too, so type errors surface from
        // `swift build` without Xcode. iOS-only API stays out of this target.
        .target(name: "ArrdeckUI", dependencies: ["ArrdeckKit", "ArrdeckData"]),
        .testTarget(
            name: "ArrdeckKitTests",
            dependencies: ["ArrdeckKit", "ArrdeckAPI"]
        ),
        .testTarget(
            name: "ArrdeckDataTests",
            dependencies: [
                "ArrdeckData", "ArrdeckAPI",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ]
        ),
    ]
)
