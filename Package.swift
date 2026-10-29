// swift-tools-version:5.9
import PackageDescription

// FocusCore   = pure logic: the judge, the scoring, the rubric, the local brain. Unit tested.
// HermesFocus = thin AppKit/SwiftUI shell around it.
let package = Package(
    name: "HermesFocus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HermesFocus", targets: ["HermesFocus"])],
    targets: [
        .target(name: "FocusCore"),
        .executableTarget(name: "HermesFocus", dependencies: ["FocusCore"]),
        .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"]),
    ]
)
