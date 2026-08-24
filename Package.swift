// swift-tools-version: 6.0

// ArrdeckKit is everything the app does that is not a screen: profiles, the
// backend probe, capability handling, storage. It is deliberately buildable on
// macOS so `swift test` runs on a machine with only Command Line Tools — the
// Xcode app target (App/) merely consumes it.
import PackageDescription

let package = Package(
    name: "arrdeck-ios",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ArrdeckKit", targets: ["ArrdeckKit"]),
        .library(name: "ArrdeckUI", targets: ["ArrdeckUI"]),
    ],
    targets: [
        .target(name: "ArrdeckKit"),
        // Views compile against the macOS SDK too, so type errors surface from
        // `swift build` without Xcode. iOS-only API stays out of this target.
        .target(name: "ArrdeckUI", dependencies: ["ArrdeckKit"]),
        .testTarget(name: "ArrdeckKitTests", dependencies: ["ArrdeckKit"]),
    ]
)
