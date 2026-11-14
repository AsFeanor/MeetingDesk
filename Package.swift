// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "MeetingDesk",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MeetingDesk", targets: ["MeetingDesk"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"])
    ],
    targets: [
        .executableTarget(name: "MeetingDesk", dependencies: [.product(name: "Sparkle", package: "Sparkle"), .product(name: "FluidAudio", package: "FluidAudio")],
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MeetingDeskTests", dependencies: ["MeetingDesk"], exclude: ["SpeakerFixtures", "WorkspaceFixtures"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
