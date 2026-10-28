// swift-tools-version:5.9
// Kun til at køre logik-testene lokalt (fx på Linux): swift test -c release -Xswiftc -enable-testing
// Appen selv bygges med XcodeGen (project.yml).
import PackageDescription

let package = Package(
    name: "KameraLogic",
    targets: [
        .target(name: "KameraLogic", path: "KameraPlus/Logic"),
        .testTarget(name: "KameraLogicTests", dependencies: ["KameraLogic"], path: "KameraPlusTests"),
    ]
)
