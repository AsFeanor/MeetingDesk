// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MeetingDesk",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MeetingDesk", targets: ["MeetingDesk"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(name: "MeetingDesk", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MeetingDeskTests", dependencies: ["MeetingDesk"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
