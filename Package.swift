// swift-tools-version: 6.2
import PackageDescription

let testingFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

let package = Package(
    name: "Dictate",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "DictateCore", targets: ["DictateCore"]),
        .executable(name: "Dictate", targets: ["Dictate"]),
    ],
    targets: [
        .target(name: "DictateCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Dictate",
            dependencies: ["DictateCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DictateChecks",
            dependencies: ["DictateCore"],
            path: "Tests/DictateCoreTests",
            swiftSettings: [.unsafeFlags(["-F", testingFrameworks])],
            linkerSettings: [.unsafeFlags(["-F", testingFrameworks, "-Xlinker", "-rpath", "-Xlinker", testingFrameworks])]
        ),
    ]
)
