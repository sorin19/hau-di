// swift-tools-version: 5.10
// Harness for checks on Linux: builds and tests the portable code in hau-di/Core.
// Run with: Tools/linux-check/run.sh (it copies the sources into a temporary directory).
import PackageDescription

let package = Package(
    name: "HauDiCoreCheck",
    targets: [
        .target(name: "HauDiCore", path: "Sources/HauDiCore"),
        .testTarget(name: "HauDiCoreTests", dependencies: ["HauDiCore"], path: "Tests/HauDiCoreTests"),
    ]
)
