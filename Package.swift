// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIPassport",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "PassportCore", targets: ["PassportCore"]),
        .executable(name: "AIPassport", targets: ["AIPassport"])
    ],
    targets: [
        .target(name: "PassportCore"),
        .executableTarget(name: "AIPassport", dependencies: ["PassportCore"]),
        .executableTarget(name: "ProtocolChecks", dependencies: ["PassportCore"], path: "Tests/PassportCoreTests")
    ]
)
