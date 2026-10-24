// swift-tools-version: 6.4
import PackageDescription

// The app is a plain SwiftPM executable; scripts/install.sh wraps it into Murmur.app
// (Info.plist, resources, code signature). No Xcode project needed.
let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
    ],
    targets: [
        // Text processing with no app dependencies: vocabulary, spoken paths/commands.
        .target(name: "MurmurCore"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"]),
    ]
)
