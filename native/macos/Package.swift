// swift-tools-version: 5.9
import PackageDescription
import Foundation
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path
let package = Package(
    name: "VTrackerCapture",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "vtracker-capture", targets: ["VTrackerCapture"]),
        .executable(name: "VTASK", targets: ["VTASK"])
    ],
    targets: [.executableTarget(name: "VTrackerCapture", linkerSettings: [
        .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
    ]), .executableTarget(name: "VTASK", resources: [.copy("Resources/meeting-topics.json")])]
)
