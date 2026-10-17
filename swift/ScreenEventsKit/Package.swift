// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenEventsKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ScreenEventsKit", targets: ["ScreenEventsKit"])],
    targets: [
        .target(name: "ScreenEventsKit"),
        .testTarget(name: "ScreenEventsKitTests", dependencies: ["ScreenEventsKit"]),
    ]
)
