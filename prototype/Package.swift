// swift-tools-version: 6.4
import PackageDescription

// The Info.plist is embedded into the binary's __TEXT,__info_plist section so the
// CLI carries a bundle identifier and the microphone / speech usage strings.
let infoPlist = Context.packageDirectory + "/Info.plist"

let package = Package(
    name: "murmur-prototype",
    platforms: [.macOS(.v27)],
    targets: [
        .executableTarget(
            name: "murmur-cli",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ]
        )
    ]
)
