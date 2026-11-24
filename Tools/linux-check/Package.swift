// swift-tools-version: 5.10
// Harness pentru verificari pe Linux: compileaza si testeaza codul portabil din hau-di/Core.
// Rulare: Tools/linux-check/run.sh (copiaza sursele intr-un director temporar).
import PackageDescription

let package = Package(
    name: "HauDiCoreCheck",
    targets: [
        .target(name: "HauDiCore", path: "Sources/HauDiCore"),
        .testTarget(name: "HauDiCoreTests", dependencies: ["HauDiCore"], path: "Tests/HauDiCoreTests"),
    ]
)
